//
//  GLES2Shader.swift
//  PyShader
//
//  Python source in, OpenGL ES 2 (GLSL ES 1.00) out: the shader language
//  Kivy draws with. The same Python module that compiles to SPIR-V compiles
//  here, through the same checks; what OpenGL ES 2 cannot express (compute
//  storage, unsigned and bitwise integers, loops without constant bounds…)
//  is an error at the Python line that uses it.
//

import Foundation

/// A shader compiled for OpenGL ES 2: a vertex and a fragment stage in
/// GLSL ES 1.00, using Kivy's names for what Kivy hands a shader.
public struct GLES2Shader: Sendable, Equatable {
    /// The vertex stage. For a fragment or compute target it is Kivy's own
    /// default vertex shader, written out: `vPosition` and `vTexCoords0` in,
    /// `frag_color` and `tex_coord0` out.
    public let vertex: String
    /// The fragment stage, writing `gl_FragColor`.
    public let fragment: String

    public init(vertex: String, fragment: String) {
        self.vertex = vertex
        self.fragment = fragment
    }

    /// Both stages in Kivy's single-file format, what `Shader.source` (a
    /// `.glsl` file) loads: a `---VERTEX SHADER---` and a
    /// `---FRAGMENT SHADER---` section.
    public var kivySource: String {
        "---VERTEX SHADER---\n" + vertex + "\n---FRAGMENT SHADER---\n" + fragment
    }
}

extension PyShader {
    /// Compiles Python shader source for OpenGL ES 2.
    /// - Parameters:
    ///   - target: The PyShader target the module is written for. A fragment
    ///     target becomes a fragment stage behind Kivy's default vertex
    ///     stage; a compute target too, one fragment per pixel of the
    ///     widget; a graphics target both of its stages.
    ///   - sourceFile: The `.py` file's name, named in the generated source's header.
    ///   - modules: The site-packages folder its imports are installed in, as for SPIR-V.
    public static func compileGLES2(_ source: String, target: ShaderTarget, sourceFile: String? = nil, modules: URL? = nil) throws -> GLES2Shader {
        try compileGLES2(source, target: target, sourceFile: sourceFile, searching: modules.map(ShaderModules.init(sitePackages:)) ?? .none)
    }

    /// `compileGLES2(_:target:sourceFile:modules:)` with the modules handed over as
    /// sources, dotted name to source, as `compile(_:target:sourceFile:modules:)` takes them.
    public static func compileGLES2(_ source: String, target: ShaderTarget, sourceFile: String? = nil, modules: [String: String]) throws -> GLES2Shader {
        try compileGLES2(source, target: target, sourceFile: sourceFile, searching: ShaderModules(sources: modules))
    }

    /// Compiles a `.py` file for OpenGL ES 2; its imports are found as `compile(contentsOf:target:modules:)` finds them.
    public static func compileGLES2(contentsOf file: URL, target: ShaderTarget, modules: URL? = nil) throws -> GLES2Shader {
        let source = try String(contentsOf: file, encoding: .utf8)
        return try compileGLES2(source, target: target, sourceFile: file.lastPathComponent, searching: .discover(near: file, sitePackages: modules))
    }

    /// `compileGLES2(contentsOf:target:modules:)` with the site-packages folder as a path.
    public static func compileGLES2(contentsOf file: URL, target: ShaderTarget, modules: String?) throws -> GLES2Shader {
        try compileGLES2(contentsOf: file, target: target, modules: modules.map { URL(fileURLWithPath: $0) })
    }

    static func compileGLES2(_ source: String, target: ShaderTarget, sourceFile: String?, searching modules: ShaderModules) throws -> GLES2Shader {
        let linker = ModuleLinker(modules: modules)
        let module = try linker.link(parse(source))
        let target = target.inferringTextures(from: module)
        let program = try ShaderProgram(module: module, target: target, origins: linker.origins)
        return try GLES2Compiler(program: program, sourceFile: sourceFile).compile()
    }
}
