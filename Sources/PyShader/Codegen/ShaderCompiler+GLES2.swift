//
//  ShaderCompiler+GLES2.swift
//  PyShader
//
//  The entry points of a module compiled for OpenGL ES 2. The functions are
//  the same SPIR-V as for Vulkan; only the wrappers that call the Python
//  entry points differ, taking OpenGL ES 2's interface: attributes and
//  varyings under the names `GLES2Options` gives, the inputs and arguments
//  as plain uniforms of their own names (OpenGL SPIR-V's UniformConstant
//  values), gl_FragCoord lower-left as GL has it, and the color written to
//  the one fragment output, gl_FragColor. Spirv2GLSL writes the result as
//  GLSL ES 1.00.
//
//      fragment target   a fragment stage: uv and color the varyings the
//                        generated vertex stage passes on, the push
//                        constants uniforms
//      compute target    one fragment per pixel of the quad drawn: uv the
//                        varying, frag_coord uv * resolution, pixel from it
//      graphics target   both stages: the vertex stage's attributes, its
//                        position through the matrices to gl_Position, the
//                        other fields `v_<field>` varyings
//

import SpirvCore

extension ShaderCompiler {
    func emitGLES2EntryPoints(_ options: GLES2Options) throws {
        switch program.target {
        case .fragment(let interface): try emitGLES2Fragment(interface, options)
        case .computeImage(let interface): try emitGLES2Compute(interface, options)
        case .graphics(let interface): try emitGLES2Graphics(interface, options)
        }
    }

    // MARK: Interface variables

    /// The module variable `name` of `storage`, made once; one name is one variable.
    private func glVariable(_ name: String, _ type: ShaderType, _ storage: SpirvStorageClass, line: Int,
                            decorate: (SpirvId) -> Void = { _ in }) throws -> SpirvId {
        if let known = glVariables[name] {
            guard known.type == type, known.storage == storage else {
                throw PyShaderError("`\(name)` is both a `\(known.type)` and a `\(type)` in the OpenGL ES 2 interface", line: line)
            }
            return known.id
        }
        let v = builder.globalVariable(type: type, storage: storage, name: name)
        decorate(v)
        glVariables[name] = (v, type, storage)
        return v
    }

    private func glUniform(_ name: String, _ type: ShaderType, line: Int) throws -> SpirvId {
        try glVariable(name, type, .uniformConstant, line: line)
    }

    private func glInput(_ name: String, _ type: ShaderType, location: Int, line: Int) throws -> SpirvId {
        try glVariable(name, type, .input, line: line) { self.builder.decorate($0, .location, [UInt32(location)]) }
    }

    private func glOutput(_ name: String, _ type: ShaderType, location: Int, line: Int) throws -> SpirvId {
        try glVariable(name, type, .output, line: line) { self.builder.decorate($0, .location, [UInt32(location)]) }
    }

    private func glBuiltIn(_ b: SpirvBuiltIn, _ name: String, _ type: ShaderType, _ storage: SpirvStorageClass, line: Int) throws -> SpirvId {
        try glVariable(name, type, storage, line: line) { self.builder.decorate($0, .builtIn, [b.rawValue]) }
    }

    /// The entry point `main` of `model`, its body written by `body` after
    /// the line of the Python `def`, which errors about the interface name.
    private func glEntryPoint(_ model: SpirvExecutionModel, def line: Int, file: String?, _ body: (FunctionEmitter) throws -> Void) throws {
        let id = builder.allocate()
        builder.name(id, "main")
        let wrapper = FunctionEmitter(compiler: self, name: "main", returnType: .void)
        try wrapper.emitWrapper(id: id) { e in
            if let marker = self.builder.line(line, in: file) { e.emit(marker) }
            try body(e)
        }
        // SPIR-V 1.0 lists the Input and Output variables the entry point uses.
        let interface = glVariables.values.filter { $0.storage == .input || $0.storage == .output }.map(\.id)
        builder.addEntryPoint(model: model, function: id, name: "main", interface: interface)
        if model == .fragment { builder.addExecutionMode(function: id, mode: .originLowerLeft) }
    }

    // MARK: Fragment target

    private func emitGLES2Fragment(_ interface: FragmentInterface, _ options: GLES2Options) throws {
        let main = program.functions[interface.entryPoint]!
        let line = main.def.lineno
        let file = program.origin(of: interface.entryPoint)
        guard interface.output.type == .float(4) else {
            throw PyShaderError("OpenGL ES 2 writes a `float4` color (`gl_FragColor`), not a `\(interface.output.type)`", line: line)
        }
        let output = try glOutput("gl_FragColor", .float(4), location: 0, line: line)
        var loads: [(FunctionEmitter) throws -> Value] = []
        for param in main.params {
            if let input = interface.inputs.first(where: { $0.name == param.name }) {
                switch input.binding {
                case .builtIn(let b):
                    switch b.spirv {
                    case .fragCoord:
                        let v = try glBuiltIn(.fragCoord, "gl_FragCoord", .float(4), .input, line: line)
                        loads.append { e in
                            let c = e.load(v, type: .float(4))
                            return input.type == .float(2) ? e.swizzle(c, [0, 1]) : c
                        }
                    case .pointCoord:
                        let v = try glBuiltIn(.pointCoord, "gl_PointCoord", .float(2), .input, line: line)
                        loads.append { $0.load(v, type: .float(2)) }
                    case .frontFacing:
                        let v = try glBuiltIn(.frontFacing, "gl_FrontFacing", .bool, .input, line: line)
                        loads.append { $0.load(v, type: .bool) }
                    default:
                        throw PyShaderError("`\(param.name)` has no OpenGL ES 2 counterpart", line: line)
                    }
                case .location(let l):
                    let name: String
                    if param.name == "uv" { name = options.uvVarying; glReadsUV = true }
                    else if param.name == "color" { name = options.colorVarying; glReadsColor = true }
                    else { name = param.name }
                    let v = try glInput(name, input.type, location: l, line: line)
                    loads.append { $0.load(v, type: input.type) }
                }
            } else if let constant = interface.pushConstants.first(where: { $0.name == param.name }) {
                let v = try glUniform(constant.name, constant.type, line: line)
                loads.append { $0.load(v, type: constant.type) }
            } else {
                throw PyShaderError("`\(param.name)` is not a shader input", line: line)
            }
        }
        try glEntryPoint(.fragment, def: line, file: file) { e in
            let args = try loads.map { try $0(e) }
            let result = e.emit(.opFunctionCall, type: main.returnType, [main.id] + args.map(\.id))
            e.store(output, result.id)
        }
    }

    // MARK: Compute target

    private func emitGLES2Compute(_ interface: ComputeImageInterface, _ options: GLES2Options) throws {
        let main = program.functions[interface.entryPoint]!
        let line = main.def.lineno
        let file = program.origin(of: interface.entryPoint)
        let output = try glOutput("gl_FragColor", .float(4), location: 0, line: line)
        try glEntryPoint(.fragment, def: line, file: file) { e in
            var uv: Value?
            func readUV() throws -> Value {
                if let uv { return uv }
                let v = try self.glInput(options.uvVarying, .float(2), location: 0, line: line)
                self.glReadsUV = true
                uv = e.load(v, type: .float(2))
                return uv!
            }
            var resolution: Value?
            func readResolution() throws -> Value {
                if let resolution { return resolution }
                resolution = e.load(try self.glUniform("resolution", .float(2), line: line), type: .float(2))
                return resolution!
            }
            var fragCoord: Value?
            func readFragCoord() throws -> Value {
                if let fragCoord { return fragCoord }
                fragCoord = e.emit(.opFMul, type: .float(2), [try readUV().id, try readResolution().id])
                return fragCoord!
            }
            var args: [SpirvId] = []
            for param in main.params {
                if let input = interface.inputs[param.name] {
                    switch input {
                    case .uv:
                        args.append(try readUV().id)
                    case .fragCoord:
                        args.append(try readFragCoord().id)
                    case .pixel:
                        // y-down, as the compute target's store location is.
                        let c = try readFragCoord()
                        let h = e.swizzle(try readResolution(), [1])
                        let y = e.emit(.opFSub, type: .float, [h.id, e.swizzle(c, [1]).id])
                        let p = e.emit(.opCompositeConstruct, type: .float(2), [e.swizzle(c, [0]).id, y.id])
                        args.append(try e.convert(p, to: .int(2), line: line).id)
                    case .resolution:
                        args.append(try readResolution().id)
                    default:
                        args.append(e.load(try self.glUniform(param.name, input.type, line: line), type: input.type).id)
                    }
                } else if let argument = interface.arguments.first(where: { $0.name == param.name }) {
                    args.append(e.load(try self.glUniform(argument.name, argument.kind.type, line: line), type: argument.kind.type).id)
                } else if interface.textures.contains(where: { $0.name == param.name }) {
                    continue   // a handle: the sampler is a uniform the body names
                } else {
                    throw PyShaderError("`\(param.name)` is not a shader input", line: line)
                }
            }
            let result = e.emit(.opFunctionCall, type: main.returnType, [main.id] + args)
            e.store(output, result.id)
        }
    }

    // MARK: Graphics target

    private func emitGLES2Graphics(_ interface: GraphicsInterface, _ options: GLES2Options) throws {
        let vertex = program.functions[interface.vertexEntryPoint]!
        let fragment = program.functions[interface.fragmentEntryPoint]!
        guard case .structure(_, let members) = vertex.returnType else { preconditionFailure() }
        let varyings = Array(members.dropFirst())
        let vertexLine = vertex.def.lineno
        let fragmentLine = fragment.def.lineno
        let mat4 = ShaderType.matrix(.float(bits: 32), columns: 4, rows: 4)

        // Vertex: the attributes in, gl_Position and the varyings out.
        let position = try glBuiltIn(.position, "gl_Position", .float(4), .output, line: vertexLine)
        var outputs: [SpirvId] = []
        for (k, (name, type)) in varyings.enumerated() {
            let v = try glOutput("v_" + name, type, location: k, line: vertexLine)
            outputs.append(v)
        }
        var nextAttribute = 3
        try glEntryPoint(.vertex, def: vertexLine, file: program.origin(of: interface.vertexEntryPoint)) { e in
            func attribute(_ name: String, _ type: ShaderType, location: Int) throws -> Value {
                let v = try self.glInput(name, type, location: location, line: vertexLine)
                return e.load(v, type: type)
            }
            var args: [SpirvId] = []
            for param in vertex.params {
                if let input = interface.inputs[param.name] {
                    switch input {
                    case .positionAttribute(let size):
                        args.append(try attribute(options.positionAttribute, .float(size), location: 0).id)
                    case .texcoordAttribute:
                        args.append(try attribute(options.texcoordAttribute, .float(2), location: 1).id)
                    case .colorAttribute:
                        args.append(try attribute(options.colorAttribute, .float(4), location: 2).id)
                    case .attribute(let type):
                        args.append(try attribute(param.name, type, location: nextAttribute).id)
                        nextAttribute += 1
                    case .vertexIndex:
                        let v = try self.glBuiltIn(.vertexIndex, "gl_VertexIndex", .int, .input, line: vertexLine)
                        args.append(e.load(v, type: .int).id)
                    case .instanceIndex:
                        let v = try self.glBuiltIn(.instanceIndex, "gl_InstanceIndex", .int, .input, line: vertexLine)
                        args.append(e.load(v, type: .int).id)
                    case .uv, .fragCoord, .pixel, .frontFacing:
                        throw PyShaderError("`\(param.name)` is a fragment input, not available in `\(interface.vertexEntryPoint)`", line: vertexLine)
                    default:
                        args.append(e.load(try self.glUniform(param.name, input.type, line: vertexLine), type: input.type).id)
                    }
                } else if let argument = interface.arguments.first(where: { $0.name == param.name }) {
                    args.append(e.load(try self.glUniform(argument.name, argument.kind.type, line: vertexLine), type: argument.kind.type).id)
                } else if interface.textures.contains(where: { $0.name == param.name }) {
                    continue
                } else {
                    throw PyShaderError("`\(param.name)` is not a shader input", line: vertexLine)
                }
            }
            let result = e.emit(.opFunctionCall, type: vertex.returnType, [vertex.id] + args)
            var clip = e.emit(.opCompositeExtract, type: .float(4), [result.id, 0])
            // p * m * position, left to right.
            let matrices = try options.positionMatrices.map { e.load(try self.glUniform($0, mat4, line: vertexLine), type: mat4) }
            if var combined = matrices.first {
                for m in matrices.dropFirst() { combined = e.emit(.opMatrixTimesMatrix, type: mat4, [combined.id, m.id]) }
                clip = e.emit(.opMatrixTimesVector, type: .float(4), [combined.id, clip.id])
            }
            e.store(position, clip.id)
            for (k, (_, type)) in varyings.enumerated() {
                let field = e.emit(.opCompositeExtract, type: type, [result.id, UInt32(k + 1)])
                e.store(outputs[k], field.id)
            }
        }

        // Fragment: the varyings and gl_FragCoord in, gl_FragColor out.
        let color = try glOutput("gl_FragColor", .float(4), location: 0, line: fragmentLine)
        try glEntryPoint(.fragment, def: fragmentLine, file: program.origin(of: interface.fragmentEntryPoint)) { e in
            func varying(_ k: Int) throws -> Value {
                let (name, type) = varyings[k]
                // The vertex stage's output's location; its name is the vertex stage's.
                let v = try self.glInput("f_v_" + name, type, location: k, line: fragmentLine)
                return e.load(v, type: type)
            }
            var coord: Value?
            func fragCoord() throws -> Value {
                if let coord { return coord }
                let v = try self.glBuiltIn(.fragCoord, "gl_FragCoord", .float(4), .input, line: fragmentLine)
                coord = e.load(v, type: .float(4))
                return coord!
            }
            var resolution: Value?
            func readResolution() throws -> Value {
                if let resolution { return resolution }
                resolution = e.load(try self.glUniform("resolution", .float(2), line: fragmentLine), type: .float(2))
                return resolution!
            }
            var args: [SpirvId] = []
            for param in fragment.params {
                if param.type == vertex.returnType {
                    // The vertex stage's class again, its position the fragment's own.
                    let fields = try varyings.indices.map { try varying($0).id }
                    args.append(e.emit(.opCompositeConstruct, type: vertex.returnType, [try fragCoord().id] + fields).id)
                } else if let k = varyings.firstIndex(where: { $0.0 == param.name }) {
                    args.append(try varying(k).id)
                } else if let input = interface.inputs[param.name] {
                    switch input {
                    case .uv:
                        let xy = e.swizzle(try fragCoord(), [0, 1])
                        args.append(e.emit(.opFDiv, type: .float(2), [xy.id, try readResolution().id]).id)
                    case .fragCoord:
                        args.append(e.swizzle(try fragCoord(), [0, 1]).id)
                    case .pixel:
                        let c = try fragCoord()
                        let h = e.swizzle(try readResolution(), [1])
                        let y = e.emit(.opFSub, type: .float, [h.id, e.swizzle(c, [1]).id])
                        let p = e.emit(.opCompositeConstruct, type: .float(2), [e.swizzle(c, [0]).id, y.id])
                        args.append(try e.convert(p, to: .int(2), line: fragmentLine).id)
                    case .frontFacing:
                        let v = try self.glBuiltIn(.frontFacing, "gl_FrontFacing", .bool, .input, line: fragmentLine)
                        args.append(e.load(v, type: .bool).id)
                    case .resolution:
                        args.append(try readResolution().id)
                    case .vertexIndex, .instanceIndex, .positionAttribute, .texcoordAttribute, .colorAttribute, .attribute:
                        throw PyShaderError("`\(param.name)` is a vertex input, not available in `\(interface.fragmentEntryPoint)`", line: fragmentLine)
                    default:
                        args.append(e.load(try self.glUniform(param.name, input.type, line: fragmentLine), type: input.type).id)
                    }
                } else if let argument = interface.arguments.first(where: { $0.name == param.name }) {
                    args.append(e.load(try self.glUniform(argument.name, argument.kind.type, line: fragmentLine), type: argument.kind.type).id)
                } else if interface.textures.contains(where: { $0.name == param.name }) {
                    continue
                } else {
                    throw PyShaderError("`\(param.name)` is not a shader input", line: fragmentLine)
                }
            }
            let result = e.emit(.opFunctionCall, type: fragment.returnType, [fragment.id] + args)
            e.store(color, result.id)
        }
    }
}
