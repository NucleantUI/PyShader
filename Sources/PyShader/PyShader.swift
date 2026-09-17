//
//  PyShader.swift
//  PyShader
//
//  Public entry point: Python source in, SPIR-V words out.
//

import Foundation
@_exported import SpirvCore
import PySwiftAST

/// A compiled shader ready for `vkCreateShaderModule`.
public struct CompiledShader: Sendable {
    /// SPIR-V words (little-endian, magic first).
    public let spirv: [UInt32]
    /// Name of the SPIR-V entry point (`pName` for the pipeline stage). For a
    /// `.graphics` target this is the fragment stage's; see `vertexEntryPoint`.
    public let entryPoint: String
    /// The vertex stage's entry point in the same module, for a `.graphics`
    /// target; nil for a single-stage one.
    public let vertexEntryPoint: String?

    init(spirv: [UInt32], entryPoint: String, vertexEntryPoint: String? = nil) {
        self.spirv = spirv
        self.entryPoint = entryPoint
        self.vertexEntryPoint = vertexEntryPoint
    }

    /// The same words as raw bytes, e.g. for writing a `.spv` file.
    public var bytes: Data {
        spirv.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

public enum PyShader {
    /// Compiles Python shader source to a SPIR-V fragment shader.
    /// - Parameters:
    ///   - source: Python source text following the PyShader subset.
    ///   - interface: What the host pipeline provides; defaults to NucleantVulkan's `NucleantShader` layout.
    public static func compile(_ source: String, interface: FragmentInterface = .nucleant) throws -> CompiledShader {
        try compile(source, target: .fragment(interface))
    }

    /// Compiles Python shader source for the given target: a fragment stage, a
    /// compute-into-image stage, or a vertex + fragment pair in one module.
    public static func compile(_ source: String, target: ShaderTarget) throws -> CompiledShader {
        let module: Module
        do {
            module = try parsePython(normalize(source))
        } catch let error as PyShaderError {
            throw error
        } catch {
            throw PyShaderError("syntax error: \(error)")
        }
        let program = try ShaderProgram(module: module, target: target)
        let compiler = ShaderCompiler(program: program)
        let words = try compiler.compile()
        var vertexEntryPoint: String?
        if case .graphics(let i) = target { vertexEntryPoint = i.vertexEntryPoint }
        return CompiledShader(spirv: words, entryPoint: target.entryPoint, vertexEntryPoint: vertexEntryPoint)
    }

    /// Strips the indentation shared by every non-blank line (source embedded in a
    /// Swift multi-line string literal is indented as a block) and makes sure the
    /// text ends in a newline, which the parser wants after the last statement.
    static func normalize(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let indents = lines
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        let common = indents.min() ?? 0
        let dedented = lines.map { line -> Substring in
            line.allSatisfy(\.isWhitespace) ? "" : line.dropFirst(common)
        }
        var text = dedented.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }
}
