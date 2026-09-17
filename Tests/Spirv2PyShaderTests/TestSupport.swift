import Foundation
import Testing
import PyShader
import SpirvCore
@testable import Spirv2PyShader

enum Tools {
    static func find(_ name: String) -> String? {
        for p in ["/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    static let spirvVal = find("spirv-val")
    static let spirvOpt = find("spirv-opt")
    static let glslang = find("glslangValidator")

    static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    /// spirv-val's complaint, "" when valid, nil when the tool is missing.
    static func validate(_ words: [UInt32]) throws -> String? {
        guard let tool = spirvVal else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spirv2py-\(UUID().uuidString).spv")
        try words.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (status, output) = try run(tool, ["--target-env", "vulkan1.0", url.path])
        return status == 0 ? "" : output
    }

    /// `spirv-opt -O`; nil when the tool is missing.
    static func optimize(_ words: [UInt32]) throws -> [UInt32]? {
        guard let tool = spirvOpt else { return nil }
        let dir = FileManager.default.temporaryDirectory
        let input = dir.appendingPathComponent("spirv2py-\(UUID().uuidString).spv")
        let output = dir.appendingPathComponent("spirv2py-\(UUID().uuidString).spv")
        try words.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: input)
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        let (status, log) = try run(tool, ["--target-env=vulkan1.0", "-O", input.path, "-o", output.path])
        guard status == 0 else { throw Spirv2PyShaderError("spirv-opt: \(log)") }
        let data = try Data(contentsOf: output)
        return data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }

    /// GLSL fragment source through glslang; nil when the tool is missing.
    static func compileGLSL(_ source: String) throws -> [UInt32]? {
        guard let tool = glslang else { return nil }
        let dir = FileManager.default.temporaryDirectory
        let input = dir.appendingPathComponent("spirv2py-\(UUID().uuidString).frag")
        let output = dir.appendingPathComponent("spirv2py-\(UUID().uuidString).spv")
        try source.write(to: input, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        let (status, log) = try run(tool, ["-V", input.path, "-o", output.path])
        guard status == 0 else { throw Spirv2PyShaderError("glslang: \(log)") }
        let data = try Data(contentsOf: output)
        return data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }
}

let packageRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Spirv2PyShaderTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
}()

func exampleSources(_ subdirectory: String = "Examples", suffix: String = ".py") throws -> [(name: String, source: String)] {
    let dir = packageRoot.appendingPathComponent(subdirectory)
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(suffix) }.sorted()
    return try files.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
}

/// Wraps ShaderToy-style GLSL (`mainImage`) into a complete fragment shader
/// against `FragmentInterface.shaderToy`.
func wrapShaderToy(_ body: String) -> String {
    ShaderToy.wrap(body)
}

/// Decompiles, expects no warnings, compiles the result with PyShader for the
/// same interface and validates it.
@discardableResult
func decompileAndRecompile(_ words: [UInt32], interface: FragmentInterface = .nucleant, sourceLocation: SourceLocation = #_sourceLocation) throws -> DecompiledShader {
    let decompiled = try Spirv2PyShader.decompile(words, interface: interface)
    #expect(decompiled.warnings.isEmpty, "warnings: \(decompiled.warnings)", sourceLocation: sourceLocation)
    let recompiled: CompiledShader
    do {
        recompiled = try PyShader.compile(decompiled.source, target: .fragment(interface))
    } catch {
        Issue.record("PyShader rejected the decompiled source: \(error)\n\(decompiled.source)", sourceLocation: sourceLocation)
        return decompiled
    }
    if let result = try Tools.validate(recompiled.spirv) {
        #expect(result.isEmpty, "spirv-val: \(result)\n\(decompiled.source)", sourceLocation: sourceLocation)
    }
    return decompiled
}
