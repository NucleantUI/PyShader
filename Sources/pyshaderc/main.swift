//
//  pyshaderc: compile a PyShader .py file to a SPIR-V .spv file.
//
//  usage: pyshaderc <input.py> [-o output.spv] [--target fragment|compute|graphics]
//                   [--content] [--arg name:float|float2|float3|float4|floatArray|float2Array|float3Array|float4Array]...
//
//  `--target compute` builds for NucleantSwiftUI's `Shader` view (storage image),
//  `--target graphics` for its `VertexShader` view (vertex + fragment, one module);
//  `--content` adds the sampled content image (`layer()`), `--arg` a ShaderArgument.
//

import Foundation
import PyShader

func usage() -> Never {
    FileHandle.standardError.write("""
    usage: pyshaderc <input.py> [-o output.spv] [--target fragment|compute|graphics] [--content] [--arg name:kind]...

    """.data(using: .utf8)!)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var output: String?
var targetName = "fragment"
var samplesContent = false
var arguments: [(name: String, kind: ShaderArgumentKind)] = []
var inputs: [String] = []

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
case "compute": target = .computeImage(.nucleantSwiftUI(samplesContent: samplesContent, arguments: arguments))
case "graphics": target = .graphics(.nucleantSwiftUI(samplesContent: samplesContent, arguments: arguments))
default: usage()
}

do {
    let source = try String(contentsOfFile: input, encoding: .utf8)
    let shader = try PyShader.compile(source, target: target)
    let outPath = output ?? (input as NSString).deletingPathExtension + ".spv"
    try shader.bytes.write(to: URL(fileURLWithPath: outPath))
    print("\(outPath): \(shader.spirv.count) words")
} catch {
    FileHandle.standardError.write("\(input): \(error)\n".data(using: .utf8)!)
    exit(1)
}
