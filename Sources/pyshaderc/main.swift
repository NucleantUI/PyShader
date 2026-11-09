//
//  pyshaderc: compile a PyShader .py file to a SPIR-V .spv file, or to an
//  OpenGL ES 2 shader (`--format gles2`).
//
//  usage: pyshaderc <input.py> [-o output] [--target fragment|compute|graphics]
//                   [--format spirv|gles2]
//                   [--content] [--content-top-down] [--textures-top-down] [--arg name:float|float2|float3|float4|floatArray|float2Array|float3Array|float4Array]...
//                   [--site-packages dir] [--optimize flag]...
//
//  `--target compute` builds for NucleantUI's `Shader` view (storage image),
//  `--target graphics` for its `VertexShader` view (vertex + fragment, one module);
//  `--content` adds the sampled content image (`layer()`), stored y-up;
//  `--content-top-down` adds it stored top-down, as NucleantUI 0.0.3 and later
//  hand a module every image; `--arg` a ShaderArgument. Every `Texture`
//  parameter of the entry point(s) is a texture, bound from 4 in the order
//  they are declared and read y-up; `--textures-top-down` reads them top-down.
//  `--format gles2` writes GLSL ES 1.00 for OpenGL ES 2 instead, as one Kivy
//  `.glsl` file holding both stages (default output `<input>.glsl`).
//  Imports are found next to the input, then in `--site-packages` — by default
//  the site-packages of the nearest uv `.venv` above the input.
//  `--optimize` runs a spirv-opt pass over the module (`-O`, `-Os`,
//  `--strip-debug`, …), in the order given, and validates the result; SPIR-V only.
//

import Foundation
import PyShader
import SpirvTools

func usage() -> Never {
    FileHandle.standardError.write("""
    usage: pyshaderc <input.py> [-o output] [--target fragment|compute|graphics] [--format spirv|gles2] [--content] [--content-top-down] [--textures-top-down] [--arg name:kind]... [--site-packages dir] [--optimize flag]...

    """.data(using: .utf8)!)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var output: String?
var targetName = "fragment"
var format = "spirv"
var samplesContent = false
var contentIsTopDown = false
var texturesAreTopDown = false
var arguments: [(name: String, kind: ShaderArgumentKind)] = []
var inputs: [String] = []
var sitePackages: String?
var optimize: [String] = []

while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "-o":
        guard !args.isEmpty else { usage() }
        output = args.removeFirst()
    case "--target":
        guard !args.isEmpty else { usage() }
        targetName = args.removeFirst()
    case "--format":
        guard !args.isEmpty else { usage() }
        format = args.removeFirst()
        guard format == "spirv" || format == "gles2" else { usage() }
    case "--content":
        samplesContent = true
    case "--content-top-down":
        samplesContent = true
        contentIsTopDown = true
    case "--textures-top-down":
        texturesAreTopDown = true
    case "--site-packages":
        guard !args.isEmpty else { usage() }
        sitePackages = args.removeFirst()
    case "--optimize":
        guard !args.isEmpty else { usage() }
        optimize.append(args.removeFirst())
    case "--arg":
        guard !args.isEmpty else { usage() }
        let spec = args.removeFirst().split(separator: ":", maxSplits: 1).map(String.init)
        guard spec.count == 2 else { usage() }
        let kind: ShaderArgumentKind
        switch spec[1] {
        case "float": kind = .float
        case "float2": kind = .float2
        case "float3": kind = .float3
        case "float4": kind = .float4
        case "floatArray": kind = .floatArray
        case "float2Array": kind = .float2Array
        case "float3Array": kind = .float3Array
        case "float4Array": kind = .float4Array
        default: usage()
        }
        arguments.append((spec[0], kind))
    default:
        if a.hasPrefix("-") { usage() }
        inputs.append(a)
    }
}
guard inputs.count == 1 else { usage() }
let input = inputs[0]

let target: ShaderTarget
switch targetName {
case "fragment": target = .nucleant
case "compute": target = .computeImage(.nucleantUI(samplesContent: samplesContent, contentIsTopDown: contentIsTopDown, arguments: arguments, texturesAreTopDown: texturesAreTopDown))
case "graphics": target = .graphics(.nucleantUI(samplesContent: samplesContent, contentIsTopDown: contentIsTopDown, arguments: arguments, texturesAreTopDown: texturesAreTopDown))
default: usage()
}

/// The source line an error points at, indented under the message: the code
/// the error is about, as the build log shows it.
func excerpt(_ line: Int) -> String {
    guard let text = try? String(contentsOf: URL(fileURLWithPath: input), encoding: .utf8) else { return "" }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.indices.contains(line - 1) else { return "" }
    let code = lines[line - 1].trimmingCharacters(in: .whitespaces)
    return code.isEmpty ? "" : "    \(code)\n"
}

do {
    let base = (input as NSString).deletingPathExtension
    if format == "gles2" {
        guard optimize.isEmpty else {
            throw SpirvDiagnostic(message: "--optimize runs spirv-opt, which only applies to --format spirv")
        }
        let shader = try PyShader.compileGLES2(contentsOf: URL(fileURLWithPath: input), target: target, modules: sitePackages)
        let outPath = output ?? base + ".glsl"
        try Data(shader.kivySource.utf8).write(to: URL(fileURLWithPath: outPath))
        print("\(outPath): OpenGL ES 2, \(shader.kivySource.split(separator: "\n").count) lines")
    } else {
        let shader = try PyShader.compile(contentsOf: URL(fileURLWithPath: input), target: target, modules: sitePackages)
        var words = shader.spirv
        if !optimize.isEmpty {
            let tools = SpirvContext()
            words = try tools.optimize(words, flags: optimize)
            if let invalid = tools.validate(words) {
                throw SpirvDiagnostic(message: "the module is not valid after \(optimize.joined(separator: " ")): \(invalid)")
            }
        }
        let outPath = output ?? base + ".spv"
        try words.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: outPath))
        print("\(outPath): \(words.count) words" + (optimize.isEmpty ? "" : " (\(shader.spirv.count) before \(optimize.joined(separator: " ")))"))
    }
} catch let error as PyShaderError where error.file == nil && error.line != nil {
    // `file:line: error:` — what editors and build logs link to the source.
    FileHandle.standardError.write("\(input):\(error.line!): error: \(error.message)\n\(excerpt(error.line!))".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("\(input): error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
