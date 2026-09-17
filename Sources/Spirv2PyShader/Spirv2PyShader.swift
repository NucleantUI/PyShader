//
//  Spirv2PyShader.swift
//  Spirv2PyShader
//
//  Public entry point: SPIR-V words in, PyShader source out.
//
//  The decompiler reads a fragment stage and writes the Python PyShader
//  compiles back to the same thing: one `def` per function, `main` taking
//  its inputs by the names the `FragmentInterface` gives them, GLSL `out`
//  parameters turned into tuple returns and uniforms threaded into the
//  helpers that read them as parameters.
//

import Foundation
import PyShader
import SpirvCore

public struct Spirv2PyShaderError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct DecompileOptions: Sendable {
    /// Python names for interface variables the `FragmentInterface` does not
    /// describe, keyed by their SPIR-V (member) name: `["iTime": "time"]`.
    public var renames: [String: String]
    /// The entry point to decompile when the module has several; the first
    /// fragment entry point when nil.
    public var entryPoint: String?
    /// Whether to put a `# decompiled from ...` line at the top.
    public var header: Bool

    public init(renames: [String: String] = [:], entryPoint: String? = nil, header: Bool = true) {
        self.renames = renames
        self.entryPoint = entryPoint
        self.header = header
    }
}

public struct DecompiledShader: Sendable {
    /// PyShader source.
    public let source: String
    /// Constructs that have no exact PyShader spelling; the source still
    /// compiles where possible, with the nearest equivalent.
    public let warnings: [String]
    /// The Python function that is the entry point.
    public let entryPoint: String
}

public enum Spirv2PyShader {
    /// Decompiles a fragment shader module to PyShader source.
    /// - Parameters:
    ///   - words: SPIR-V words, magic first.
    ///   - interface: How the host pipeline feeds the stage; interface variables
    ///     are named after it, so a shader compiled against NucleantVulkan's
    ///     layout comes back with `uv`, `time`, `resolution`, …
    public static func decompile(_ words: [UInt32], interface: FragmentInterface = .nucleant, options: DecompileOptions = .init()) throws -> DecompiledShader {
        try decompile(reader: { try SpirvModuleReader(words: words) }, interface: interface, options: options)
    }

    /// Decompiles the bytes of a `.spv` file.
    public static func decompile(_ data: Data, interface: FragmentInterface = .nucleant, options: DecompileOptions = .init()) throws -> DecompiledShader {
        try decompile(reader: { try SpirvModuleReader(data: data) }, interface: interface, options: options)
    }

    private static func decompile(reader: () throws -> SpirvModuleReader, interface: FragmentInterface, options: DecompileOptions) throws -> DecompiledShader {
        let module: ModuleIndex
        do {
            module = try ModuleIndex(reader: try reader())
        } catch let error as SpirvReadError {
            throw Spirv2PyShaderError(error.message)
        }
        return try ModuleDecompiler(module: module, interface: interface, options: options).decompile()
    }
}
