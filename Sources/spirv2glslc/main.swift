//
//  spirv2glslc: a SPIR-V module's vertex and fragment stages as GLSL ES 1.00
//  (OpenGL ES 2), from any compiler's SPIR-V.
//
//  usage: spirv2glslc <input.spv> [-o output] [--stage vertex|fragment] [--entry name]
//                     [--version 100] [--precision highp|mediump] [--any-loops]
//                     [--texture-lod-extension]
//
//  With no --stage, every vertex and fragment stage the module has: `-o x`
//  writes x.vert and x.frag, the fragment stage's varyings named as the
//  vertex stage's. With --stage, the one stage, to -o or stdout.
//

import Foundation
import Spirv2GLSL

func usage() -> Never {
    FileHandle.standardError.write("""
    usage: spirv2glslc <input.spv> [-o output] [--stage vertex|fragment] [--entry name]
                       [--version 100] [--precision highp|mediump] [--any-loops] [--texture-lod-extension]

    """.data(using: .utf8)!)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var output: String?
var stage: GLSLESStage?
var entry: String?
var options = GLSLESOptions()
var inputs: [String] = []

while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "-o":
        guard !args.isEmpty else { usage() }
        output = args.removeFirst()
    case "--stage":
        guard !args.isEmpty else { usage() }
        switch args.removeFirst() {
        case "vertex": stage = .vertex
        case "fragment": stage = .fragment
        default: usage()
        }
    case "--entry":
        guard !args.isEmpty else { usage() }
        entry = args.removeFirst()
    case "--version":
        guard !args.isEmpty else { usage() }
        options.version = args.removeFirst()
    case "--precision":
        guard !args.isEmpty else { usage() }
        options.floatPrecision = args.removeFirst()
    case "--any-loops":
        options.loopsFollowAppendixA = false
    case "--texture-lod-extension":
        options.fragmentExplicitLod = .shaderTextureLodExtension
    default:
        if a.hasPrefix("-") { usage() }
        inputs.append(a)
    }
}
guard inputs.count == 1 else { usage() }

@MainActor func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(inputs[0]): error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

do {
    let translator = try GLSLESTranslator(data: try Data(contentsOf: URL(fileURLWithPath: inputs[0])), options: options)
    if let stage {
        let shader = try translator.translate(stage: stage, entryPoint: entry)
        if let output {
            try shader.source.write(toFile: output, atomically: true, encoding: .utf8)
        } else {
            print(shader.source, terminator: "")
        }
    } else {
        var varyings: [Int: String] = [:]
        var wrote = false
        for s in [GLSLESStage.vertex, .fragment] where !translator.entryPoints(of: s).isEmpty {
            let shader = try translator.translate(stage: s, entryPoint: entry, varyingNames: varyings)
            if s == .vertex { varyings = shader.varyingNames }
            if let output {
                try shader.source.write(toFile: output + (s == .vertex ? ".vert" : ".frag"), atomically: true, encoding: .utf8)
            } else {
                print("// ---- \(s == .vertex ? "vertex" : "fragment") ----")
                print(shader.source, terminator: "")
            }
            wrote = true
        }
        if !wrote { fail("the module has no vertex or fragment stage") }
    }
} catch let error as Spirv2GLSLError {
    if let line = error.line {
        FileHandle.standardError.write("\(error.file ?? inputs[0]):\(line): error: \(error.message)\n".data(using: .utf8)!)
        exit(1)
    }
    fail(error.message)
} catch {
    fail("\(error)")
}
