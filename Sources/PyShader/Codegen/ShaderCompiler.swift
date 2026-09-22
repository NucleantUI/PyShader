//
//  ShaderCompiler.swift
//  PyShader
//
//  Drives code generation for one module: emits every user function, the
//  monomorphized lambdas, and the SPIR-V entry point that wires the target's
//  resources (inputs, uniforms, images, argument buffer) to the Python `main`.
//

import SpirvCore
import PySwiftAST

final class ShaderCompiler {
    let builder = SpirvModuleBuilder()
    let program: ShaderProgram
    private var callGraph: [String: Swift.Set<String>] = [:]
    private var inlining: [String] = []
    private var lambdaInstances: [String: (id: SpirvId, returnType: ShaderType)] = [:]
    private var lambdaCounter = 0

    /// Compute-target resources, created on first use.
    private var contentImage: SpirvId?
    private var argumentBuffer: SpirvId?

    /// The module variables as `Private` globals, and the function that
    /// initializes them, which every entry-point wrapper calls first.
    private(set) var variables: [String: LocalVariable] = [:]
    private(set) var globalsInit: SpirvId?

    init(program: ShaderProgram) {
        self.program = program
    }

    func compile() throws -> [UInt32] {
        // Ids first so calls can reference functions defined later in the file.
        for name in program.functionOrder {
            let id = builder.allocate()
            program.assignFunctionId(name, id)
            builder.name(id, program.isEntry(name) ? "py_\(name)" : name)
        }

        try emitGlobalsInit()

        for name in program.functionOrder {
            let fn = program.functions[name]!
            let forwards = program.entry(named: name)?.forwardsColor ?? false
            let emitter = FunctionEmitter(
                compiler: self,
                name: name,
                returnType: fn.returnType,
                implicitReturn: forwards ? { try Self.forwardColor($0, entry: name, line: fn.def.lineno) } : nil
            )
            try emitter.emitFunction(id: fn.id, params: fn.params, body: fn.def.body, line: fn.def.lineno)
        }

        try checkRecursion()
        switch program.target {
        case .fragment(let interface): try emitFragmentEntryPoint(interface)
        case .computeImage(let interface): try emitComputeEntryPoint(interface)
        case .graphics(let interface): try emitGraphicsEntryPoints(interface)
        }
        return builder.build()
    }

    // MARK: - Module variables

    func variable(_ name: String) -> LocalVariable? { variables[name] }

    /// `py_globals`: evaluates each module variable's initializer, in order,
    /// into a fresh `Private` variable. Emitted before the user functions so
    /// they know the variables' types; a helper an initializer calls may not
    /// read the variable being initialized, or a later one.
    private func emitGlobalsInit() throws {
        guard !program.variableOrder.isEmpty else { return }
        let id = builder.allocate()
        builder.name(id, "py_globals")
        let emitter = FunctionEmitter(compiler: self, name: "py_globals", returnType: .void)
        try emitter.emitWrapper(id: id) { e in
            for name in self.program.variableOrder {
                let g = self.program.variables[name]!
                var value = try e.emitExpression(g.expr)
                if let annotation = g.annotation {
                    let type = try self.program.resolveType(annotation, line: g.line)
                    value = try e.coerce(value, to: type, line: g.line)
                }
                guard value.type.isStorable else {
                    throw PyShaderError("cannot store a `\(value.type)` in the module variable `\(name)`", line: g.line)
                }
                let ptr = self.builder.globalVariable(type: value.type, storage: .private, name: name)
                e.store(ptr, value.id)
                self.variables[name] = LocalVariable(ptr: ptr, type: value.type)
            }
        }
        globalsInit = id
    }

    // MARK: - Shared resources

    /// The `Uniforms { vec4 timeInfo; vec4 res; vec4 mouseInfo; }` block the
    /// compute and graphics targets share, declared once per module.
    private var uniformsVariable: SpirvId?

    private func uniformsBlock(set: Int, binding: Int) -> SpirvId {
        if let v = uniformsVariable { return v }
        let uniformsType = ShaderType.structure(name: "Uniforms", members: [
            ("timeInfo", .float(4)), ("res", .float(4)), ("mouseInfo", .float(4)),
        ])
        let uniformsStruct = builder.type(uniformsType)
        builder.decorate(uniformsStruct, .block)
        for (i, offset) in [0, 16, 32].enumerated() {
            builder.memberDecorate(uniformsStruct, i, .offset, [UInt32(offset)])
        }
        let v = builder.globalVariable(type: uniformsType, storage: .uniform, name: "u")
        builder.decorate(v, .descriptorSet, [UInt32(set)])
        builder.decorate(v, .binding, [UInt32(binding)])
        uniformsVariable = v
        return v
    }

    /// One `vec4` member of the uniforms block.
    private func uniform(_ member: Int, block: SpirvId, _ e: FunctionEmitter) -> Value {
        let ptr = e.emit(.opAccessChain, type: .pointer(.uniform, .float(4)), [block, e.builder.constant(int: member)])
        return e.load(ptr.id, type: .float(4))
    }

    /// A scalar or vector `ShaderArgument`, loaded from the argument buffer;
    /// nil for an array, which is a compile-time handle rather than a value.
    private func argumentValue(_ argument: (name: String, kind: ShaderArgumentKind), at index: Int, _ e: FunctionEmitter, line: Int) throws -> Value? {
        if argument.kind.isArray { return nil }
        let offset = try e.convert(loadArgument(e, at: e.builder.constant(int: index * 2)), to: .int, line: line)
        return loadArgument(e, at: offset, type: argument.kind.type)
    }

    /// `type` (a float or vector) read from the argument buffer starting at float index `at`.
    private func loadArgument(_ e: FunctionEmitter, at offset: Value, type: ShaderType) -> Value {
        var components: [SpirvId] = []
        for k in 0..<type.componentCount {
            let at = e.emit(.opIAdd, type: .int, [offset.id, e.builder.constant(int: k)])
            components.append(loadArgument(e, at: at.id).id)
        }
        return components.count == 1
            ? Value(id: components[0], type: .float)
            : e.emit(.opCompositeConstruct, type: type, components)
    }

    /// `(x, resolution.y - y)`: a y-down pair from the uniforms in shader space.
    private func flipped(_ pair: Value, _ x: Int, _ y: Int, resolution: Value, _ e: FunctionEmitter) -> Value {
        let px = e.swizzle(pair, [x]), py = e.swizzle(pair, [y])
        let h = e.swizzle(resolution, [1])
        let fy = e.emit(.opFSub, type: .float, [h.id, py.id])
        return e.emit(.opCompositeConstruct, type: .float(2), [px.id, fy.id])
    }

    // MARK: - Fragment entry point

    private func emitFragmentEntryPoint(_ interface: FragmentInterface) throws {
        let main = program.functions[interface.entryPoint]!
        var interfaceIds: [SpirvId] = []

        let output = builder.globalVariable(type: interface.output.type, storage: .output, name: interface.output.name)
        builder.decorate(output, .location, [UInt32(interface.output.location)])
        interfaceIds.append(output)

        var pushConstantVar: SpirvId?
        func pushConstantBlock() -> SpirvId {
            if let v = pushConstantVar { return v }
            let structType = ShaderType.structure(
                name: interface.pushConstantBlockName,
                members: interface.pushConstants.map { ($0.name, $0.type) }
            )
            let structId = builder.type(structType)
            builder.decorate(structId, .block)
            for (i, m) in interface.pushConstants.enumerated() {
                builder.memberDecorate(structId, i, .offset, [UInt32(m.offset)])
            }
            let v = builder.globalVariable(type: structType, storage: .pushConstant, name: "pc")
            pushConstantVar = v
            return v
        }

        // Interface variables are declared before the wrapper body so the entry point can list them.
        var loads: [(FunctionEmitter) -> Value] = []
        for param in main.params {
            if let input = interface.inputs.first(where: { $0.name == param.name }) {
                let v = builder.globalVariable(type: input.type, storage: .input, name: input.name)
                switch input.binding {
                case .location(let l): builder.decorate(v, .location, [UInt32(l)])
                case .builtIn(let b): builder.decorate(v, .builtIn, [b.spirv.rawValue])
                }
                interfaceIds.append(v)
                loads.append { $0.load(v, type: input.type) }
            } else if let index = interface.pushConstants.firstIndex(where: { $0.name == param.name }) {
                let member = interface.pushConstants[index]
                let block = pushConstantBlock()
                loads.append { e in
                    let ptr = e.emit(.opAccessChain, type: .pointer(.pushConstant, member.type), [block, e.builder.constant(int: index)])
                    return e.load(ptr.id, type: member.type)
                }
            } else {
                throw PyShaderError("`\(param.name)` is not a shader input", line: main.def.lineno)
            }
        }

        let fnId = builder.allocate()
        builder.name(fnId, interface.entryPoint)
        builder.addEntryPoint(model: .fragment, function: fnId, name: interface.entryPoint, interface: interfaceIds)
        builder.addExecutionMode(function: fnId, mode: .originUpperLeft)

        let wrapper = FunctionEmitter(compiler: self, name: interface.entryPoint, returnType: .void)
        try wrapper.emitWrapper(id: fnId) { e in
            let args = loads.map { $0(e) }
            let result = e.emit(.opFunctionCall, type: main.returnType, [main.id] + args.map(\.id))
            e.store(output, result.id)
        }
    }

    // MARK: - Compute (storage image) entry point

    private func emitComputeEntryPoint(_ interface: ComputeImageInterface) throws {
        let main = program.functions[interface.entryPoint]!
        let set = UInt32(interface.descriptorSet)

        let globalId = builder.globalVariable(type: .uint(3), storage: .input, name: "gl_GlobalInvocationID")
        builder.decorate(globalId, .builtIn, [SpirvBuiltIn.globalInvocationId.rawValue])

        let output = builder.globalVariable(type: .image(.storage2DRgba8), storage: .uniformConstant, name: "uOutput")
        builder.decorate(output, .descriptorSet, [set])
        builder.decorate(output, .binding, [UInt32(interface.outputBinding)])
        builder.decorate(output, .nonReadable)
        builder.require(.imageQuery)

        let uniforms = uniformsBlock(set: interface.descriptorSet, binding: interface.uniformBinding)

        let fnId = builder.allocate()
        builder.name(fnId, interface.entryPoint)
        builder.addEntryPoint(model: .glCompute, function: fnId, name: interface.entryPoint, interface: [globalId])
        builder.addExecutionMode(function: fnId, mode: .localSize, operands: [UInt32(interface.localSize.x), UInt32(interface.localSize.y), 1])

        let line = main.def.lineno
        let wrapper = FunctionEmitter(compiler: self, name: interface.entryPoint, returnType: .void)
        try wrapper.emitWrapper(id: fnId) { e in
            let gid = e.load(globalId, type: .uint(3))
            let pixel = try e.convert(e.swizzle(gid, [0, 1]), to: .int(2), line: line)
            let image = e.load(output, type: .image(.storage2DRgba8))
            let size = e.emit(.opImageQuerySize, type: .int(2), [image.id])

            // if pixel.x >= size.x or pixel.y >= size.y: return
            let outside = e.emit(.opSGreaterThanEqual, type: .bool(2), [pixel.id, size.id])
            e.emitReturnIf(e.emit(.opAny, type: .bool, [outside.id]))

            // Shader space is y-up with (0, 0) bottom-left, as ShaderToy has it; the image is
            // stored top-down, so coordinates handed to the body are flipped and `pixel` is not.
            lazy var resolution: Value = try! e.convert(size, to: .float(2), line: line)
            lazy var timeInfo: Value = self.uniform(0, block: uniforms, e)
            lazy var mouseInfo: Value = self.uniform(2, block: uniforms, e)
            lazy var fragCoord: Value = {
                let p = try! e.convert(pixel, to: .float(2), line: line)
                let px = e.swizzle(p, [0]), py = e.swizzle(p, [1])
                let half = e.builder.constant(float: 0.5)
                let x = e.emit(.opFAdd, type: .float, [px.id, half])
                let h = e.swizzle(resolution, [1])
                let flipped = e.emit(.opFSub, type: .float, [h.id, py.id])
                let y = e.emit(.opFSub, type: .float, [flipped.id, half])
                return e.emit(.opCompositeConstruct, type: .float(2), [x.id, y.id])
            }()
            var args: [SpirvId] = []
            for param in main.params {
                if let input = interface.inputs[param.name] {
                    let value: Value
                    switch input {
                    case .uv: value = e.emit(.opFDiv, type: .float(2), [fragCoord.id, resolution.id])
                    case .fragCoord: value = fragCoord
                    case .pixel: value = pixel
                    case .time: value = e.swizzle(timeInfo, [0])
                    case .timeDelta: value = e.swizzle(timeInfo, [1])
                    case .frame: value = try e.convert(e.swizzle(timeInfo, [2]), to: .int, line: line)
                    case .resolution: value = resolution
                    case .mouse: value = self.flipped(mouseInfo, 0, 1, resolution: resolution, e)
                    case .mouseClick: value = self.flipped(mouseInfo, 2, 3, resolution: resolution, e)
                    }
                    args.append(value.id)
                } else if let index = interface.arguments.firstIndex(where: { $0.name == param.name }) {
                    if let value = try self.argumentValue(interface.arguments[index], at: index, e, line: line) {
                        args.append(value.id)
                    }
                } else {
                    throw PyShaderError("`\(param.name)` is not a shader input", line: line)
                }
            }

            let color = e.emit(.opFunctionCall, type: main.returnType, [main.id] + args)
            e.emit(.init(.opImageWrite, [image.id, pixel.id, color.id]))
        }
    }


    // MARK: - Graphics (vertex + fragment) entry points

    /// Two entry points in one module. The vertex wrapper calls `py_vertex`,
    /// writes the first member of its struct to `gl_Position` (y flipped into
    /// Vulkan's clip space) and the rest to `Output` variables at locations
    /// 0…n-1; the fragment wrapper reads those back as `Input`s and hands them
    /// to `py_fragment` by name alongside the built-in inputs.
    private func emitGraphicsEntryPoints(_ interface: GraphicsInterface) throws {
        let vertex = program.functions[interface.vertexEntryPoint]!
        let fragment = program.functions[interface.fragmentEntryPoint]!
        guard case .structure(_, let members) = vertex.returnType else { preconditionFailure() }
        let varyings = Array(members.dropFirst())
        let uniforms = uniformsBlock(set: interface.descriptorSet, binding: interface.uniformBinding)

        // MARK: Vertex

        var vertexInterface: [SpirvId] = []
        let position = builder.globalVariable(type: .float(4), storage: .output, name: "gl_Position")
        builder.decorate(position, .builtIn, [SpirvBuiltIn.position.rawValue])
        vertexInterface.append(position)

        var outputs: [SpirvId] = []
        for (location, (name, type)) in varyings.enumerated() {
            let v = builder.globalVariable(type: type, storage: .output, name: "v_\(name)")
            builder.decorate(v, .location, [UInt32(location)])
            outputs.append(v)
            vertexInterface.append(v)
        }

        var vertexIndex: SpirvId?
        var instanceIndex: SpirvId?
        func builtIn(_ b: SpirvBuiltIn, type: ShaderType, name: String, into list: inout [SpirvId]) -> SpirvId {
            let v = builder.globalVariable(type: type, storage: .input, name: name)
            builder.decorate(v, .builtIn, [b.rawValue])
            list.append(v)
            return v
        }
        for param in vertex.params {
            switch interface.inputs[param.name] {
            case .vertexIndex where vertexIndex == nil:
                vertexIndex = builtIn(.vertexIndex, type: .int, name: "gl_VertexIndex", into: &vertexInterface)
            case .instanceIndex where instanceIndex == nil:
                instanceIndex = builtIn(.instanceIndex, type: .int, name: "gl_InstanceIndex", into: &vertexInterface)
            default:
                break
            }
        }

        let vertexId = builder.allocate()
        builder.name(vertexId, interface.vertexEntryPoint)
        builder.addEntryPoint(model: .vertex, function: vertexId, name: interface.vertexEntryPoint, interface: vertexInterface)

        let vertexLine = vertex.def.lineno
        let vertexWrapper = FunctionEmitter(compiler: self, name: interface.vertexEntryPoint, returnType: .void)
        try vertexWrapper.emitWrapper(id: vertexId) { e in
            lazy var timeInfo: Value = self.uniform(0, block: uniforms, e)
            lazy var resolution: Value = e.swizzle(self.uniform(1, block: uniforms, e), [0, 1])
            lazy var mouseInfo: Value = self.uniform(2, block: uniforms, e)

            var args: [SpirvId] = []
            for param in vertex.params {
                if let input = interface.inputs[param.name] {
                    let value: Value
                    switch input {
                    case .vertexIndex: value = e.load(vertexIndex!, type: .int)
                    case .instanceIndex: value = e.load(instanceIndex!, type: .int)
                    case .time: value = e.swizzle(timeInfo, [0])
                    case .timeDelta: value = e.swizzle(timeInfo, [1])
                    case .frame: value = try e.convert(e.swizzle(timeInfo, [2]), to: .int, line: vertexLine)
                    case .resolution: value = resolution
                    case .mouse: value = self.flipped(mouseInfo, 0, 1, resolution: resolution, e)
                    case .mouseClick: value = self.flipped(mouseInfo, 2, 3, resolution: resolution, e)
                    case .uv, .fragCoord, .pixel, .frontFacing:
                        throw PyShaderError("`\(param.name)` is a fragment input, not available in `\(interface.vertexEntryPoint)`", line: vertexLine)
                    }
                    args.append(value.id)
                } else if let index = interface.arguments.firstIndex(where: { $0.name == param.name }) {
                    if let value = try self.argumentValue(interface.arguments[index], at: index, e, line: vertexLine) {
                        args.append(value.id)
                    }
                } else {
                    throw PyShaderError("`\(param.name)` is not a shader input", line: vertexLine)
                }
            }

            let result = e.emit(.opFunctionCall, type: vertex.returnType, [vertex.id] + args)
            // Shader space is y-up; Vulkan clip space is y-down. Flip here so
            // a position written as in OpenGL lands where the author expects.
            let p = e.emit(.opCompositeExtract, type: .float(4), [result.id, 0])
            let y = e.emit(.opCompositeExtract, type: .float, [p.id, 1])
            let negated = e.emit(.opFNegate, type: .float, [y.id])
            let flipped = e.emit(.opCompositeInsert, type: .float(4), [negated.id, p.id, 1])
            e.store(position, flipped.id)
            for (i, (_, type)) in varyings.enumerated() {
                let member = e.emit(.opCompositeExtract, type: type, [result.id, UInt32(i + 1)])
                e.store(outputs[i], member.id)
            }
        }

        // MARK: Fragment

        var fragmentInterface: [SpirvId] = []
        let color = builder.globalVariable(type: .float(4), storage: .output, name: "fragColor")
        builder.decorate(color, .location, [0])
        fragmentInterface.append(color)

        var inputs: [String: SpirvId] = [:]
        for (location, (name, type)) in varyings.enumerated() where fragment.params.contains(where: { $0.name == name }) {
            let v = builder.globalVariable(type: type, storage: .input, name: "f_\(name)")
            builder.decorate(v, .location, [UInt32(location)])
            // Integers and booleans cannot be interpolated.
            if !type.isFloat { builder.decorate(v, .flat) }
            inputs[name] = v
            fragmentInterface.append(v)
        }
        var fragCoordVar: SpirvId?
        var frontFacingVar: SpirvId?
        for param in fragment.params where inputs[param.name] == nil {
            switch interface.inputs[param.name] {
            case .uv, .fragCoord, .pixel:
                if fragCoordVar == nil {
                    fragCoordVar = builtIn(.fragCoord, type: .float(4), name: "gl_FragCoord", into: &fragmentInterface)
                }
            case .frontFacing where frontFacingVar == nil:
                frontFacingVar = builtIn(.frontFacing, type: .bool, name: "gl_FrontFacing", into: &fragmentInterface)
            default:
                break
            }
        }

        let fragmentId = builder.allocate()
        builder.name(fragmentId, interface.fragmentEntryPoint)
        builder.addEntryPoint(model: .fragment, function: fragmentId, name: interface.fragmentEntryPoint, interface: fragmentInterface)
        builder.addExecutionMode(function: fragmentId, mode: .originUpperLeft)

        let fragmentLine = fragment.def.lineno
        let fragmentWrapper = FunctionEmitter(compiler: self, name: interface.fragmentEntryPoint, returnType: .void)
        try fragmentWrapper.emitWrapper(id: fragmentId) { e in
            lazy var timeInfo: Value = self.uniform(0, block: uniforms, e)
            lazy var resolution: Value = e.swizzle(self.uniform(1, block: uniforms, e), [0, 1])
            lazy var mouseInfo: Value = self.uniform(2, block: uniforms, e)
            // gl_FragCoord is y-down with the pixel centre at +0.5; shader
            // space is y-up, so only y is flipped — the centre offset survives.
            lazy var rawCoord: Value = e.swizzle(e.load(fragCoordVar!, type: .float(4)), [0, 1])
            lazy var fragCoord: Value = self.flipped(rawCoord, 0, 1, resolution: resolution, e)

            var args: [SpirvId] = []
            for param in fragment.params {
                if let v = inputs[param.name] {
                    args.append(e.load(v, type: param.type).id)
                } else if let input = interface.inputs[param.name] {
                    let value: Value
                    switch input {
                    case .uv: value = e.emit(.opFDiv, type: .float(2), [fragCoord.id, resolution.id])
                    case .fragCoord: value = fragCoord
                    case .pixel: value = try e.convert(rawCoord, to: .int(2), line: fragmentLine)
                    case .frontFacing: value = e.load(frontFacingVar!, type: .bool)
                    case .time: value = e.swizzle(timeInfo, [0])
                    case .timeDelta: value = e.swizzle(timeInfo, [1])
                    case .frame: value = try e.convert(e.swizzle(timeInfo, [2]), to: .int, line: fragmentLine)
                    case .resolution: value = resolution
                    case .mouse: value = self.flipped(mouseInfo, 0, 1, resolution: resolution, e)
                    case .mouseClick: value = self.flipped(mouseInfo, 2, 3, resolution: resolution, e)
                    case .vertexIndex, .instanceIndex:
                        throw PyShaderError("`\(param.name)` is a vertex input, not available in `\(interface.fragmentEntryPoint)`", line: fragmentLine)
                    }
                    args.append(value.id)
                } else if let index = interface.arguments.firstIndex(where: { $0.name == param.name }) {
                    if let value = try self.argumentValue(interface.arguments[index], at: index, e, line: fragmentLine) {
                        args.append(value.id)
                    }
                } else {
                    throw PyShaderError("`\(param.name)` is not a shader input", line: fragmentLine)
                }
            }

            let result = e.emit(.opFunctionCall, type: fragment.returnType, [fragment.id] + args)
            e.store(color, result.id)
        }
    }

    /// `uArgs.data[index]` as a float.
    private func loadArgument(_ e: FunctionEmitter, at index: SpirvId) -> Value {
        let buffer = argumentBufferVariable()
        let ptr = e.emit(.opAccessChain, type: .pointer(.uniform, .float), [buffer, e.builder.constant(int: 0), index])
        return e.load(ptr.id, type: .float)
    }

    private func argumentBufferVariable() -> SpirvId {
        if let v = argumentBuffer { return v }
        let binding = program.target.argumentsBinding!
        let arrayType = ShaderType.runtimeArray(.float)
        let arrayId = builder.type(arrayType)
        builder.decorate(arrayId, .arrayStride, [4])
        let blockType = ShaderType.structure(name: "ShaderArgs", members: [("data", arrayType)])
        let blockId = builder.type(blockType)
        builder.decorate(blockId, .bufferBlock)
        builder.memberDecorate(blockId, 0, .offset, [0])
        builder.memberDecorate(blockId, 0, .nonWritable)
        let v = builder.globalVariable(type: blockType, storage: .uniform, name: "uArgs")
        builder.decorate(v, .descriptorSet, [UInt32(binding.set)])
        builder.decorate(v, .binding, [UInt32(binding.binding)])
        argumentBuffer = v
        return v
    }

    /// `len(a)` for an array argument.
    func argumentArrayCount(_ argument: Int, from e: FunctionEmitter, line: Int) throws -> Value {
        guard program.target.argumentsBinding != nil else {
            throw PyShaderError("array arguments are only available in the compute and graphics targets", line: line)
        }
        return try e.convert(loadArgument(e, at: e.builder.constant(int: argument * 2 + 1)), to: .int, line: line)
    }

    /// `a[i]` for an array argument of `element`s: clamped to the ends, zero when
    /// empty. Elements are `componentCount` floats each, packed one after another.
    func loadArgumentArrayElement(_ argument: Int, element: ShaderType, index: Value, from e: FunctionEmitter, line: Int) throws -> Value {
        guard program.target.argumentsBinding != nil else {
            throw PyShaderError("array arguments are only available in the compute and graphics targets", line: line)
        }
        let count = try argumentArrayCount(argument, from: e, line: line)
        let offset = try e.convert(loadArgument(e, at: e.builder.constant(int: argument * 2)), to: .int, line: line)
        let zero = e.builder.constant(int: 0)
        let last = e.emit(.opISub, type: .int, [count.id, e.builder.constant(int: 1)])
        let clamped = e.emitExt(.sClamp, type: .int, [index.id, zero, last.id])
        let stride = e.emit(.opIMul, type: .int, [clamped.id, e.builder.constant(int: element.componentCount)])
        let at = e.emit(.opIAdd, type: .int, [offset.id, stride.id])
        let value = loadArgument(e, at: at, type: element)
        let nonEmpty = e.emit(.opSGreaterThan, type: .bool, [count.id, zero])
        return e.select(nonEmpty, value.id, e.builder.zero(of: element), type: element)
    }

    /// `layer(p)`: the view's own pixels, sampled with an explicit LOD (compute
    /// has no derivatives, and a vertex stage has none either).
    func sampleContent(at coordinate: Value, from e: FunctionEmitter, line: Int) throws -> Value {
        guard let binding = program.target.contentBinding else {
            throw PyShaderError("layer() needs a content image; this target does not provide one", line: line)
        }
        if contentImage == nil {
            let v = builder.globalVariable(type: .sampledImage(.sampled2D), storage: .uniformConstant, name: "uContent")
            builder.decorate(v, .descriptorSet, [UInt32(binding.set)])
            builder.decorate(v, .binding, [UInt32(binding.binding)])
            contentImage = v
        }
        let sampled = e.load(contentImage!, type: .sampledImage(.sampled2D))
        let lod = e.builder.constant(float: 0)
        return e.emit(.opImageSampleExplicitLod, type: .float(4), [sampled.id, coordinate.id, SpirvImageOperands.lod.rawValue, lod])
    }

    /// `return` without a value in `main` forwards the incoming `color` when it is a parameter.
    private static func forwardColor(_ emitter: FunctionEmitter, entry: String, line: Int) throws -> Value {
        let out = ShaderType.float(4)
        if let color = emitter.lookupLocal("color"), color.type == out {
            return emitter.load(color.ptr, type: color.type)
        }
        throw PyShaderError("`\(entry)` must return a `\(out)`, or take `color` as a parameter to forward it", line: line)
    }

    // MARK: Lambdas

    /// Instantiates a lambda for the given argument types (once per distinct signature) and calls it.
    func callLambda(_ template: LambdaTemplate, args: [Value], from caller: FunctionEmitter, line: Int) throws -> Value {
        let params = template.lambda.args.posonlyArgs + template.lambda.args.args
        guard params.count == args.count else {
            throw PyShaderError("`\(template.name)` takes \(params.count) argument(s), got \(args.count)", line: line)
        }
        let key = template.name + "(" + args.map { "\($0.type)" }.joined(separator: ",") + ")@\(template.line)"
        let instance: (id: SpirvId, returnType: ShaderType)
        if let existing = lambdaInstances[key] {
            instance = existing
        } else {
            lambdaCounter += 1
            let id = builder.allocate()
            let internalName = "\(template.name == "<lambda>" ? "lambda" : template.name)_\(lambdaCounter)"
            builder.name(id, internalName)
            let emitter = FunctionEmitter(compiler: self, name: internalName, returnType: .void)
            let paramList = zip(params, args).map { (name: $0.arg, type: $1.type) }
            let typed = try emitter.emitLambda(id: id, params: paramList, body: template.lambda.body, line: template.line)
            instance = (id, typed)
            lambdaInstances[key] = instance
        }
        let ids = args.map(\.id)
        return caller.emit(.opFunctionCall, type: instance.returnType, [instance.id] + ids)
    }

    // MARK: Globals

    /// Guards against `A = B; B = A` style cycles while inlining module constants.
    func withGlobalInlining<T>(_ name: String, line: Int, _ body: () throws -> T) throws -> T {
        if inlining.contains(name) {
            throw PyShaderError("module constant `\(name)` refers to itself", line: line)
        }
        inlining.append(name)
        defer { inlining.removeLast() }
        return try body()
    }

    // MARK: Call graph

    func recordCall(from: String, to: String) {
        callGraph[from, default: []].insert(to)
    }

    private func checkRecursion() throws {
        var visiting: Swift.Set<String> = []
        var done: Swift.Set<String> = []
        func visit(_ n: String, path: [String]) throws {
            if done.contains(n) { return }
            if visiting.contains(n) {
                let cycle = (path.drop(while: { $0 != n }) + [n]).joined(separator: " -> ")
                throw PyShaderError("recursion is not allowed in shader code: \(cycle)", line: program.functions[n]?.def.lineno)
            }
            visiting.insert(n)
            for m in callGraph[n] ?? [] { try visit(m, path: path + [n]) }
            visiting.remove(n)
            done.insert(n)
        }
        for n in program.functionOrder { try visit(n, path: []) }
    }
}
