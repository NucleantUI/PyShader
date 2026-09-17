import Foundation
import Testing
@testable import PyShader

/// Minimal SPIR-V word-stream reader for structural assertions.
struct SpirvWords {
    let words: [UInt32]

    struct Instruction {
        let opcode: UInt16
        let operands: [UInt32]
    }

    var bound: UInt32 { words[3] }

    var instructions: [Instruction] {
        var out: [Instruction] = []
        var i = 5
        while i < words.count {
            let count = Int(words[i] >> 16)
            let op = UInt16(words[i] & 0xFFFF)
            out.append(.init(opcode: op, operands: Array(words[(i + 1)..<(i + count)])))
            i += count
        }
        return out
    }

    func count(_ op: SpirvOp) -> Int {
        instructions.filter { $0.opcode == op.rawValue }.count
    }

    func has(_ op: SpirvOp) -> Bool { count(op) > 0 }

    func extInstCount(_ inst: GLSLstd450) -> Int {
        instructions.filter { $0.opcode == SpirvOp.opExtInst.rawValue && $0.operands.count > 3 && $0.operands[3] == inst.rawValue }.count
    }
}

enum Tools {
    static let spirvVal: String? = {
        for p in ["/usr/local/bin/spirv-val", "/opt/homebrew/bin/spirv-val"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }()

    /// Runs spirv-val on the shader; returns nil when the tool is unavailable.
    static func validate(_ shader: CompiledShader) throws -> String? {
        guard let tool = spirvVal else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pyshader-\(UUID().uuidString).spv")
        try shader.bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["--target-env", "vulkan1.0", url.path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return p.terminationStatus == 0 ? "" : output
    }
}

let examplesDirectory: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PyShaderTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("Examples")
}()

func exampleSources() throws -> [(name: String, source: String)] {
    let files = try FileManager.default.contentsOfDirectory(atPath: examplesDirectory.path)
        .filter { $0.hasSuffix(".py") }
        .sorted()
    return try files.map { ($0, try String(contentsOf: examplesDirectory.appendingPathComponent($0), encoding: .utf8)) }
}

/// Compiles, checks the header, and validates with spirv-val when present.
@discardableResult
func compileValid(_ source: String, interface: FragmentInterface = .nucleant, sourceLocation: SourceLocation = #_sourceLocation) throws -> SpirvWords {
    try compileValid(source, target: .fragment(interface), sourceLocation: sourceLocation)
}

@discardableResult
func compileValid(_ source: String, target: ShaderTarget, sourceLocation: SourceLocation = #_sourceLocation) throws -> SpirvWords {
    let shader = try PyShader.compile(source, target: target)
    #expect(shader.spirv[0] == 0x0723_0203, "magic", sourceLocation: sourceLocation)
    #expect(shader.spirv[1] == 0x0001_0000, "SPIR-V 1.0", sourceLocation: sourceLocation)
    if let result = try Tools.validate(shader) {
        #expect(result.isEmpty, "spirv-val: \(result)", sourceLocation: sourceLocation)
    }
    return SpirvWords(words: shader.spirv)
}

func compileError(_ source: String, contains needle: String, line: Int? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        _ = try PyShader.compile(source)
        Issue.record("expected an error containing \"\(needle)\"", sourceLocation: sourceLocation)
    } catch let error as PyShaderError {
        #expect(error.message.contains(needle), "got: \(error)", sourceLocation: sourceLocation)
        if let line { #expect(error.line == line, "got line \(String(describing: error.line))", sourceLocation: sourceLocation) }
    } catch {
        Issue.record("unexpected error type: \(error)", sourceLocation: sourceLocation)
    }
}
