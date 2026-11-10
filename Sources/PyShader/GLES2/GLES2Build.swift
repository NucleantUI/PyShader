//
//  GLES2Build.swift
//  PyShader
//
//  OpenGL ES 2 output is PyShader → SPIR-V → GLSL ES 1.00. The module is
//  compiled to SPIR-V as for Vulkan, with OpenGL ES 2's entry points
//  (`ShaderCompiler+GLES2`), and Spirv2GLSL writes each stage. A fragment or
//  compute target gets its vertex stage from the options: a quad passing on
//  the varyings the fragment stage reads, which holds no Python code.
//
//  What the target asks of the host that OpenGL ES 2 has no form for (array
//  arguments, storage buffers, integer varyings) is an error at the entry
//  point's `def`; what the code needs that GLSL ES 1.00 lacks, at its line.
//

import Spirv2GLSL

final class GLES2Build {
    let program: ShaderProgram
    let sourceFile: String?
    let options: GLES2Options

    init(program: ShaderProgram, sourceFile: String?, options: GLES2Options) {
        self.program = program
        self.sourceFile = sourceFile
        self.options = options
    }

    /// The name the SPIR-V's `OpLine`s give the shader being compiled.
    private var lineFile: String { sourceFile ?? "<shader>" }

    func compile() throws -> GLES2Shader {
        try checkEntries()
        let compiler = ShaderCompiler(program: program, sourceFile: lineFile, gles2: options)
        let words = try compiler.compile()
        switch program.target {
        case .fragment, .computeImage:
            let fragment = try translate(words, .fragment)
            return GLES2Shader(vertex: quadVertexStage(uv: compiler.glReadsUV, color: compiler.glReadsColor), fragment: fragment.source)
        case .graphics:
            let vertex = try translate(words, .vertex)
            let fragment = try translate(words, .fragment, varyingNames: vertex.varyingNames)
            return GLES2Shader(vertex: vertex.source, fragment: fragment.source)
        }
    }

    /// One stage through Spirv2GLSL, its errors PyShader's, at the Python line.
    private func translate(_ words: [UInt32], _ stage: GLSLESStage, varyingNames: [Int: String] = [:]) throws -> GLSLESShader {
        do {
            let translator = try GLSLESTranslator(spirv: words, options: GLSLESOptions(header: header(stage == .vertex ? "vertex" : "fragment")))
            return try translator.translate(stage: stage, varyingNames: varyingNames)
        } catch let error as Spirv2GLSLError {
            // The shader's own lines name no file; an imported module's name theirs.
            throw PyShaderError(error.message, line: error.line, file: error.file == lineFile ? nil : error.file)
        }
    }

    private func header(_ stage: String) -> String {
        let target: String
        switch program.target {
        case .fragment: target = "fragment"
        case .computeImage: target = "compute"
        case .graphics: target = "graphics"
        }
        let file = sourceFile.map { " from \($0)" } ?? ""
        return "PyShader\(file) (\(target) target): \(stage) stage, OpenGL ES 2 / GLSL ES 1.00"
    }

    // MARK: What OpenGL ES 2 cannot take

    /// The entry points' inputs that have no OpenGL ES 2 counterpart, reported
    /// at the `def` before anything else is compiled.
    private func checkEntries() throws {
        for name in program.functionOrder where program.isEntry(name) {
            let fn = program.functions[name]!
            let line = fn.def.lineno
            try PyShaderError.attributing(to: program.origin(of: name)) {
                for param in fn.params {
                    switch param.type {
                    case .floatArray:
                        throw PyShaderError("array argument `\(param.name)` has no OpenGL ES 2 equivalent: its uniforms have a size fixed in the shader, an array argument a length the app picks", line: line)
                    case .inputList:
                        throw PyShaderError("the list input `\(param.name)` is read from a storage buffer, which OpenGL ES 2 does not have", line: line)
                    default:
                        if let input = program.inputType, param.type == input, param.type != program.varyingsStruct {
                            throw PyShaderError("the class input `\(param.name)` is read from a storage buffer, which OpenGL ES 2 does not have; pass its fields as shader arguments", line: line)
                        }
                    }
                }
                if case .graphics(let i) = program.target, name == i.vertexEntryPoint, case .structure(let cls, let members) = fn.returnType {
                    for (field, type) in members.dropFirst() where !type.isFloat {
                        throw PyShaderError("varying `\(field)` of `\(cls)` is a `\(type)`: OpenGL ES 2 interpolates only floats, vectors and matrices of them", line: line)
                    }
                }
            }
        }
    }

    // MARK: The generated vertex stage

    /// The vertex stage of a fragment or compute target: a quad from
    /// `positionAttribute`, through `positionMatrices`, passing on the
    /// varyings the fragment stage reads and no others.
    private func quadVertexStage(uv: Bool, color: Bool) -> String {
        let o = options
        var declarations = ["attribute vec\(o.positionSize) \(o.positionAttribute);"]
        if uv { declarations.append("attribute vec2 \(o.texcoordAttribute);") }
        if color, o.colorUniform == nil { declarations.append("attribute vec4 \(o.colorAttribute);") }
        for matrix in o.positionMatrices { declarations.append("uniform mat4 \(matrix);") }
        if color, let uniform = o.colorUniform { declarations.append("uniform vec4 \(uniform);") }
        if color, let opacity = o.opacityUniform { declarations.append("uniform float \(opacity);") }
        if color { declarations.append("varying vec4 \(o.colorVarying);") }
        if uv { declarations.append("varying vec2 \(o.uvVarying);") }
        var body: [String] = []
        if color {
            let source = o.colorUniform ?? o.colorAttribute
            body.append("\(o.colorVarying) = \(source)" + (o.opacityUniform.map { " * vec4(1.0, 1.0, 1.0, \($0))" } ?? "") + ";")
        }
        if uv {
            let t = o.texcoordAttribute
            body.append("\(o.uvVarying) = " + (o.uvIsTopDown ? "vec2(\(t).x, 1.0 - \(t).y)" : t) + ";")
        }
        let p = o.positionAttribute
        let clip = o.positionSize == 4 ? p : o.positionSize == 3 ? "vec4(\(p).xyz, 1.0)" : "vec4(\(p).xy, 0.0, 1.0)"
        body.append("gl_Position = \((o.positionMatrices + [clip]).joined(separator: " * "));")
        var out = "// " + header("vertex")
        out += "\n\n#ifdef GL_ES\nprecision highp float;\n#endif\n\n"
        out += declarations.joined(separator: "\n")
        out += "\n\nvoid main() {\n"
        for statement in body { out += "    \(statement)\n" }
        out += "}\n"
        return out
    }
}
