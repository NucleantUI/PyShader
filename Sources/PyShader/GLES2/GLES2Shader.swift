//
//  GLES2Shader.swift
//  PyShader
//
//  Python source in, OpenGL ES 2 (GLSL ES 1.00) out. The same Python module
//  that compiles to SPIR-V compiles here, through the same checks; what
//  OpenGL ES 2 cannot express (compute storage, unsigned and bitwise
//  integers, loops without constant bounds…) is an error at the Python line
//  that uses it.
//

import Foundation

/// A shader compiled for OpenGL ES 2: a vertex and a fragment stage in
/// GLSL ES 1.00, under the names its `GLES2Options` gave.
public struct GLES2Shader: Sendable, Equatable {
    /// The vertex stage. For a fragment or compute target it is written from
    /// the options: a quad from `positionAttribute`, passing on the varyings
    /// the fragment stage reads.
    public let vertex: String
    /// The fragment stage, writing `gl_FragColor`.
    public let fragment: String

    public init(vertex: String, fragment: String) {
        self.vertex = vertex
        self.fragment = fragment
    }

    /// Both stages as one file, each after a line naming it:
    /// `---VERTEX SHADER---`, then `---FRAGMENT SHADER---`.
    public var singleFile: String {
        "---VERTEX SHADER---\n" + vertex + "\n---FRAGMENT SHADER---\n" + fragment
    }
}

extension PyShader {
    /// Compiles Python shader source for OpenGL ES 2.
    /// - Parameters:
    ///   - target: The PyShader target the module is written for. A fragment
    ///     target becomes a fragment stage behind a generated vertex stage;
    ///     a compute target too, one fragment per pixel of the quad drawn; a
    ///     graphics target both of its stages.
    ///   - sourceFile: The `.py` file's name, named in the generated source's header.
    ///   - modules: The site-packages folder its imports are installed in, as for SPIR-V.
    ///   - options: The names the stages declare, and how the generated vertex stage places its quad.
    public static func compileGLES2(_ source: String, target: ShaderTarget, sourceFile: String? = nil, modules: URL? = nil, options: GLES2Options = GLES2Options()) throws -> GLES2Shader {
        try compileGLES2(source, target: target, sourceFile: sourceFile, searching: modules.map(ShaderModules.init(sitePackages:)) ?? .none, options: options)
    }

    /// `compileGLES2(_:target:sourceFile:modules:options:)` with the modules handed over as
    /// sources, dotted name to source, as `compile(_:target:sourceFile:modules:)` takes them.
    public static func compileGLES2(_ source: String, target: ShaderTarget, sourceFile: String? = nil, modules: [String: String], options: GLES2Options = GLES2Options()) throws -> GLES2Shader {
        try compileGLES2(source, target: target, sourceFile: sourceFile, searching: ShaderModules(sources: modules), options: options)
    }

    /// Compiles a `.py` file for OpenGL ES 2; its imports are found as `compile(contentsOf:target:modules:)` finds them.
    public static func compileGLES2(contentsOf file: URL, target: ShaderTarget, modules: URL? = nil, options: GLES2Options = GLES2Options()) throws -> GLES2Shader {
        let source = try String(contentsOf: file, encoding: .utf8)
        return try compileGLES2(source, target: target, sourceFile: file.lastPathComponent, searching: .discover(near: file, sitePackages: modules), options: options)
    }

    /// `compileGLES2(contentsOf:target:modules:options:)` with the site-packages folder as a path.
    public static func compileGLES2(contentsOf file: URL, target: ShaderTarget, modules: String?, options: GLES2Options = GLES2Options()) throws -> GLES2Shader {
        try compileGLES2(contentsOf: file, target: target, modules: modules.map { URL(fileURLWithPath: $0) }, options: options)
    }

    static func compileGLES2(_ source: String, target: ShaderTarget, sourceFile: String?, searching modules: ShaderModules, options: GLES2Options) throws -> GLES2Shader {
        let linker = ModuleLinker(modules: modules)
        try options.validate()
        let module = try linker.link(parse(source))
        var target = target.inferringTextures(from: module)
        // The graphics target's vertex stage reads the vertex attributes.
        if case .graphics(var i) = target {
            let builtIn: [(String, GraphicsInterface.Input)] = [
                ("position", .positionAttribute(size: options.positionSize)),
                ("texcoord", .texcoordAttribute), ("color", .colorAttribute),
            ]
            for (name, input) in builtIn where i.inputs[name] == nil { i.inputs[name] = input }
            for (name, kind) in options.attributes.sorted(by: { $0.key < $1.key }) {
                if i.inputs[name] != nil || i.arguments.contains(where: { $0.name == name }) || i.textures.contains(where: { $0.name == name }) {
                    throw PyShaderError("attribute `\(name)` clashes with an input, argument or texture of the same name")
                }
                i.inputs[name] = .attribute(kind.type)
            }
            target = .graphics(i)
        } else if let name = options.attributes.keys.sorted().first {
            throw PyShaderError("attribute `\(name)`: only a graphics target's vertex stage takes attributes")
        }
        let program = try ShaderProgram(module: module, target: target, origins: linker.origins)
        return try GLES2Build(program: program, sourceFile: sourceFile, options: options).compile()
    }
}
