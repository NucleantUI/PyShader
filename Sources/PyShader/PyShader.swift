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
    /// `.graphics` target this is the fragment stage's — `fragment_main` for
    /// `def fragment`; see `vertexEntryPoint`.
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
    /// - Parameter sourceFile: The `.py` file's name. When given, the module names it
    ///   (`OpString`) and marks every statement with its line (`OpLine`), so
    ///   `spirv-val`, RenderDoc and naga point at the Python source. Without it the
    ///   module carries no line information.
    /// - Parameter modules: The site-packages folder the shader's imports of other
    ///   PyShader modules are installed in; only packages declaring a
    ///   `pyshader.modules` entry point can be imported from it. What the shader
    ///   uses from them is compiled in as if written in it. Without it, importing
    ///   anything besides `pyshader` is an error.
    public static func compile(_ source: String, target: ShaderTarget, sourceFile: String? = nil, modules: URL? = nil) throws -> CompiledShader {
        try compile(source, target: target, sourceFile: sourceFile, searching: modules.map(ShaderModules.init(sitePackages:)) ?? .none)
    }

    /// `compile(_:target:sourceFile:modules:)` with the site-packages folder as a path.
    public static func compile(_ source: String, target: ShaderTarget, sourceFile: String? = nil, modules: String?) throws -> CompiledShader {
        try compile(source, target: target, sourceFile: sourceFile, modules: modules.map { URL(fileURLWithPath: $0) })
    }

    /// `compile(_:target:sourceFile:modules:)` with the modules handed over as
    /// sources instead of found on disk: dotted name to source (`"noise"`,
    /// `"pyshader.stdlib.fragment.sdf"`), a package's own source being its
    /// `__init__.py`. For hosts with no file system, as the docs' previews.
    public static func compile(_ source: String, target: ShaderTarget, sourceFile: String? = nil, modules: [String: String]) throws -> CompiledShader {
        try compile(source, target: target, sourceFile: sourceFile, searching: ShaderModules(sources: modules))
    }

    /// Compiles a `.py` file, its name and lines carried into the module. Its
    /// imports are found in its own folder, then in `modules` — a site-packages
    /// folder, by default the one of the nearest uv `.venv` above the file.
    public static func compile(contentsOf file: URL, target: ShaderTarget, modules: URL? = nil) throws -> CompiledShader {
        let source = try String(contentsOf: file, encoding: .utf8)
        return try compile(source, target: target, sourceFile: file.lastPathComponent, searching: .discover(near: file, sitePackages: modules))
    }

    /// `compile(contentsOf:target:modules:)` with the site-packages folder as a path.
    public static func compile(contentsOf file: URL, target: ShaderTarget, modules: String?) throws -> CompiledShader {
        try compile(contentsOf: file, target: target, modules: modules.map { URL(fileURLWithPath: $0) })
    }

    static func compile(_ source: String, target: ShaderTarget, sourceFile: String?, searching modules: ShaderModules) throws -> CompiledShader {
        let linker = ModuleLinker(modules: modules)
        let module = try linker.link(parse(source))
        let program = try ShaderProgram(module: module, target: target, origins: linker.origins)
        let compiler = ShaderCompiler(program: program, sourceFile: sourceFile)
        let words = try compiler.compile()
        // The names in the module, which for a graphics pair are not the
        // Python ones — see `GraphicsInterface.vertexStageName`.
        if case .graphics(let i) = target {
            return CompiledShader(spirv: words, entryPoint: i.fragmentStageName, vertexEntryPoint: i.vertexStageName)
        }
        return CompiledShader(spirv: words, entryPoint: target.entryPoint)
    }

    /// Parses PyShader source, after `normalize`.
    static func parse(_ source: String) throws -> Module {
        do {
            return try parsePython(normalize(source))
        } catch let error as PyShaderError {
            throw error
        } catch {
            throw PyShaderError("syntax error: \(error)")
        }
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
