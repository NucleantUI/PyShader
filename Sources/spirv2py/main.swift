//
//  spirv2py: decompile a SPIR-V fragment shader (.spv) to a PyShader .py file.
//
//  usage: spirv2py <input.spv> [-o output.py] [--shadertoy] [--entry name] [--rename spirvName=pyName]... [--no-header]
//
//  Interface variables are named after NucleantVulkan's `NucleantShader`
//  layout (`uv`, `frag_coord`, `time`, `resolution`, `mouse`), or with
//  `--shadertoy` after `FragmentInterface.shaderToy` (what `ShaderToy.wrap`
//  compiles a `mainImage` against); `--rename` names the ones the layout
//  does not cover.
//

import Foundation
import PyShader
import Spirv2PyShader

func usage() -> Never {
    FileHandle.standardError.write("""
    usage: spirv2py <input.spv> [-o output.py] [--shadertoy] [--entry name] [--rename spirvName=pyName]... [--no-header]

    """.data(using: .utf8)!)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var output: String?
var options = DecompileOptions()
var interface = FragmentInterface.nucleant
var inputs: [String] = []

while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "-o":
        guard !args.isEmpty else { usage() }
        output = args.removeFirst()
    case "--entry":
        guard !args.isEmpty else { usage() }
        options.entryPoint = args.removeFirst()
    case "--rename":
        guard !args.isEmpty else { usage() }
        let pair = args.removeFirst().split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { usage() }
        options.renames[pair[0]] = pair[1]
    case "--no-header":
        options.header = false
    case "--shadertoy":
        interface = .shaderToy
    default:
        if a.hasPrefix("-") { usage() }
        inputs.append(a)
    }
}
guard inputs.count == 1 else { usage() }
let input = inputs[0]

do {
    let data = try Data(contentsOf: URL(fileURLWithPath: input))
    let shader = try Spirv2PyShader.decompile(data, interface: interface, options: options)
    for w in shader.warnings {
        FileHandle.standardError.write("\(input): warning: \(w)\n".data(using: .utf8)!)
    }
    if let output {
        try shader.source.write(toFile: output, atomically: true, encoding: .utf8)
        print("\(output): \(shader.source.split(separator: "\n").count) lines")
    } else {
        print(shader.source, terminator: "")
    }
} catch {
    FileHandle.standardError.write("\(input): \(error)\n".data(using: .utf8)!)
    exit(1)
}
