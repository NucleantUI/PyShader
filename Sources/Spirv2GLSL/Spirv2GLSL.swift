//
//  Spirv2GLSL.swift
//  Spirv2GLSL
//
//  SPIR-V to GLSL ES 1.00, the OpenGL ES 2 shading language: one stage of a
//  module at a time, from any SPIR-V a vertex or fragment stage can be,
//  whichever compiler wrote it. What OpenGL ES 2 has no form for is an error
//  at the source line the module's `OpLine`s name.
//
//      let translator = try GLSLESTranslator(spirv: words)
//      let vertex = try translator.translate(stage: .vertex)
//      let fragment = try translator.translate(stage: .fragment, varyingNames: vertex.varyingNames)
//
//  How the module's interface becomes GLSL ES 1.00:
//
//      Input, vertex stage              attribute, under its OpName
//      Input, fragment stage            varying
//      Output, vertex stage             varying
//      Output, fragment stage           gl_FragColor (the one at location 0)
//      BuiltIn Position, PointSize,     gl_Position, gl_PointSize,
//        FragCoord, FrontFacing,          gl_FragCoord, gl_FrontFacing,
//        PointCoord                       gl_PointCoord
//      Uniform / PushConstant block     one uniform per member, under the member's name
//      UniformConstant sampled image    uniform sampler2D / samplerCube
//      UniformConstant image + sampler  the image's uniform sampler2D (OpSampledImage)
//      UniformConstant value            uniform (OpenGL SPIR-V's loose uniforms)
//      Private                          a global
//
//  OpenGL ES 2 links varyings by name, so a fragment stage takes the names
//  its vertex stage gave each location (`varyingNames`).
//

import Foundation
import SpirvCore

/// A SPIR-V construct GLSL ES 1.00 cannot express, or a module this
/// translator cannot read, at the source line the module names.
public struct Spirv2GLSLError: Error, CustomStringConvertible, Sendable {
    public let message: String
    /// The source file the module's `OpLine` names, if it does.
    public let file: String?
    public let line: Int?

    public init(_ message: String, file: String? = nil, line: Int? = nil) {
        self.message = message
        self.file = file
        self.line = line
    }

    public var description: String {
        switch (file, line) {
        case let (file?, line?): return "\(file):\(line): \(message)"
        case let (nil, line?): return "line \(line): \(message)"
        default: return message
        }
    }
}

/// The stage a translation writes.
public enum GLSLESStage: Sendable {
    case vertex
    case fragment
}

/// How GLSL ES 1.00 is written.
public struct GLSLESOptions: Sendable, Equatable {
    /// How a fragment stage samples with an explicit level of detail, which
    /// GLSL ES 1.00 gives only the vertex stage.
    public enum FragmentExplicitLod: Sendable, Equatable {
        /// `texture2D`: the level the hardware picks, the image itself when
        /// it has no mipmaps.
        case implicit
        /// `texture2DLodEXT`, with `GL_EXT_shader_texture_lod` enabled.
        case shaderTextureLodExtension
    }

    /// The `#version` line, `"100"` for `#version 100`; nil writes none, so
    /// desktop OpenGL 2 compiles the source as well.
    public var version: String?
    /// The default float precision, declared under `#ifdef GL_ES` in both
    /// stages: `highp` or `mediump`.
    public var floatPrecision: String
    /// Loops only in the form GLSL ES 1.00's Appendix A promises every
    /// driver runs, `for (int i = a; i < b; i += c)` with constant bounds,
    /// and any other loop an error. False writes other loops as
    /// `while (true)`, which most drivers run but WebGL 1 and many OpenGL
    /// ES 2 drivers reject.
    public var loopsFollowAppendixA: Bool
    public var fragmentExplicitLod: FragmentExplicitLod
    /// GLSL ES 1.00 cannot ask a texture its size: an `ivec2` uniform of the
    /// sampler's name and this suffix holds it, which the app sets.
    public var textureSizeSuffix: String
    /// A comment written first, each line after `// `.
    public var header: String?

    public init(
        version: String? = nil,
        floatPrecision: String = "highp",
        loopsFollowAppendixA: Bool = true,
        fragmentExplicitLod: FragmentExplicitLod = .implicit,
        textureSizeSuffix: String = "_size",
        header: String? = nil
    ) {
        self.version = version
        self.floatPrecision = floatPrecision
        self.loopsFollowAppendixA = loopsFollowAppendixA
        self.fragmentExplicitLod = fragmentExplicitLod
        self.textureSizeSuffix = textureSizeSuffix
        self.header = header
    }
}

/// One stage in GLSL ES 1.00.
public struct GLSLESShader: Sendable, Equatable {
    public let source: String
    /// The name of each varying this stage declares, by location: what a
    /// fragment stage's translation takes so its varyings link with these.
    public let varyingNames: [Int: String]
    /// The uniforms the stage declares, in order, `textureSizeSuffix` ones included.
    public let uniforms: [String]
    /// The attributes a vertex stage declares, by location (-1 when it has none).
    public let attributes: [(location: Int, name: String)]

    public static func == (a: GLSLESShader, b: GLSLESShader) -> Bool {
        a.source == b.source && a.varyingNames == b.varyingNames && a.uniforms == b.uniforms
            && a.attributes.map(\.location) == b.attributes.map(\.location)
            && a.attributes.map(\.name) == b.attributes.map(\.name)
    }
}

/// Translates a SPIR-V module's vertex and fragment stages to GLSL ES 1.00.
public final class GLSLESTranslator {
    let module: SpirvModule
    public let options: GLSLESOptions

    public init(spirv words: [UInt32], options: GLSLESOptions = GLSLESOptions()) throws {
        do {
            module = try SpirvModule(words: words)
        } catch let error as SpirvReadError {
            throw Spirv2GLSLError(error.message)
        }
        self.options = options
    }

    /// A `.spv` file's bytes, either endianness.
    public convenience init(data: Data, options: GLSLESOptions = GLSLESOptions()) throws {
        let reader: SpirvModuleReader
        do {
            reader = try SpirvModuleReader(data: data)
        } catch let error as SpirvReadError {
            throw Spirv2GLSLError(error.message)
        }
        try self.init(spirv: reader.words, options: options)
    }

    /// Whether GLSL ES 1.00 lets a shader declare `name`: an identifier that
    /// is no keyword, reserved word or built-in, without `gl_` or `__`.
    public static func isDeclarableName(_ name: String) -> Bool {
        NameScope().isDeclarable(name)
    }

    /// The names of the module's entry points of `stage`.
    public func entryPoints(of stage: GLSLESStage) -> [String] {
        module.entryPoints.filter { $0.model == stage.model.rawValue }.map(\.name)
    }

    /// The stage's entry point called `entryPoint` (the only one of `stage`
    /// when nil) as GLSL ES 1.00.
    /// - Parameter varyingNames: Names for the varyings at these locations,
    ///   in place of the module's own: the vertex stage's, for a fragment stage.
    public func translate(stage: GLSLESStage, entryPoint: String? = nil, varyingNames: [Int: String] = [:]) throws -> GLSLESShader {
        let candidates = module.entryPoints.filter { $0.model == stage.model.rawValue && (entryPoint == nil || $0.name == entryPoint) }
        guard let entry = candidates.first else {
            throw Spirv2GLSLError("the module has no \(stage.description) entry point\(entryPoint.map { " called `\($0)`" } ?? "")")
        }
        guard candidates.count == 1 else {
            throw Spirv2GLSLError("the module has \(candidates.count) \(stage.description) entry points; name one: \(candidates.map(\.name).joined(separator: ", "))")
        }
        let writer = StageWriter(module: module, entry: entry, stage: stage, options: options, varyingNames: varyingNames)
        return try writer.write()
    }
}

extension GLSLESStage {
    var model: SpirvExecutionModel {
        switch self {
        case .vertex: return .vertex
        case .fragment: return .fragment
        }
    }

    var description: String {
        switch self {
        case .vertex: return "vertex"
        case .fragment: return "fragment"
        }
    }
}
