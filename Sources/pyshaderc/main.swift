//
//  pyshaderc: compile a PyShader .py file to a SPIR-V .spv file.
//
//  usage: pyshaderc <input.py> [-o output.spv] [--target fragment|compute|graphics]
//                   [--content] [--content-top-down] [--arg name:float|float2|float3|float4|floatArray|float2Array|float3Array|float4Array]...
//                   [--site-packages dir] [--optimize flag]...
//
//  `--target compute` builds for NucleantUI's `Shader` view (storage image),
//  `--target graphics` for its `VertexShader` view (vertex + fragment, one module);
//  `--content` adds the sampled content image (`layer()`), stored y-up;
//  `--content-top-down` adds it stored top-down, as NucleantUI 0.0.3 and later
//  hand a module every image; `--arg` a ShaderArgument.
//  Imports are found next to the input, then in `--site-packages` — by default
//  the site-packages of the nearest uv `.venv` above the input.
//  `--optimize` runs a spirv-opt pass over the module (`-O`, `-Os`,
//  `--strip-debug`, …), in the order given, and validates the result.
//

import Foundation
import PyShader
import SpirvTools

func usage() -> Never {
    FileHandle.standardError.write("""
    usage: pyshaderc <input.py> [-o output.spv] [--target fragment|compute|graphics] [--content] [--content-top-down] [--arg name:kind]... [--site-packages dir] [--optimize flag]...

    """.data(using: .utf8)!)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var output: String?
var targetName = "fragment"
var samplesContent = false
var contentIsTopDown = false
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
    case "--content":
        samplesContent = true
    case "--content-top-down":
        samplesContent = true
        contentIsTopDown = true
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
case "compute": target = .computeImage(.nucleantUI(samplesContent: samplesContent, contentIsTopDown: contentIsTopDown, arguments: arguments))
case "graphics": target = .graphics(.nucleantUI(samplesContent: samplesContent, contentIsTopDown: contentIsTopDown, arguments: arguments))
default: usage()
}

do {
    let shader = try PyShader.compile(contentsOf: URL(fileURLWithPath: input), target: target, modules: sitePackages)
    var words = shader.spirv
    if !optimize.isEmpty {
        let tools = SpirvContext()
        words = try tools.optimize(words, flags: optimize)
        if let invalid = tools.validate(words) {
            throw SpirvDiagnostic(message: "the module is not valid after \(optimize.joined(separator: " ")): \(invalid)")
        }
    }
    let outPath = output ?? (input as NSString).deletingPathExtension + ".spv"
    try words.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: outPath))
    print("\(outPath): \(words.count) words" + (optimize.isEmpty ? "" : " (\(shader.spirv.count) before \(optimize.joined(separator: " ")))"))
} catch let error as PyShaderError where error.file == nil && error.line != nil {
    // `file:line: error:` — what editors and build logs link to the source.
    FileHandle.standardError.write("\(input):\(error.line!): error: \(error.message)\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("\(input): error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
