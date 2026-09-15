//
//  ShaderCompiler.swift
//  PyShader
//
//  Drives code generation for one module: emits every user function, the
//  monomorphized lambdas, and the SPIR-V entry point that wires the target's
//  resources (inputs, uniforms, images, argument buffer) to the Python `main`.
//

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

    init(program: ShaderProgram) {
        self.program = program
    }

    func compile() throws -> [UInt32] {
        // Ids first so calls can reference functions defined later in the file.
        for name in program.functionOrder {
            let id = builder.allocate()
            program.assignFunctionId(name, id)
            builder.name(id, name == program.entryPoint ? "py_\(name)" : name)
        }

        for name in program.functionOrder {
            let fn = program.functions[name]!
            let isEntry = name == program.entryPoint
            let emitter = FunctionEmitter(
                compiler: self,
                name: name,
                returnType: fn.returnType,
                implicitReturn: isEntry ? { try Self.forwardColor($0, program: self.program, line: fn.def.lineno) } : nil
            )
            try emitter.emitFunction(id: fn.id, params: fn.params, body: fn.def.body, line: fn.def.lineno)
        }

        try checkRecursion()
        switch program.target {
        case .fragment(let interface): try emitFragmentEntryPoint(interface)
        case .computeImage(let interface): try emitComputeEntryPoint(interface)
        }
        return builder.build()
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

        let uniformsType = ShaderType.structure(name: "Uniforms", members: [
            ("timeInfo", .float(4)), ("res", .float(4)), ("mouseInfo", .float(4)),
        ])
        let uniformsStruct = builder.type(uniformsType)
        builder.decorate(uniformsStruct, .block)
        for (i, offset) in [0, 16, 32].enumerated() {
            builder.memberDecorate(uniformsStruct, i, .offset, [UInt32(offset)])
        }
        let uniforms = builder.globalVariable(type: uniformsType, storage: .uniform, name: "u")
        builder.decorate(uniforms, .descriptorSet, [set])
        builder.decorate(uniforms, .binding, [UInt32(interface.uniformBinding)])

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

            func uniform(_ member: Int) -> Value {
                let ptr = e.emit(.opAccessChain, type: .pointer(.uniform, .float(4)), [uniforms, e.builder.constant(int: member)])
                return e.load(ptr.id, type: .float(4))
            }

            // Shader space is y-up with (0, 0) bottom-left, as ShaderToy has it; the image is
            // stored top-down, so coordinates handed to the body are flipped and `pixel` is not.
            lazy var resolution: Value = try! e.convert(size, to: .float(2), line: line)
            lazy var timeInfo: Value = uniform(0)
            lazy var mouseInfo: Value = uniform(2)
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
            func flippedPointer(_ x: Int, _ y: Int) -> Value {
                let mx = e.swizzle(mouseInfo, [x]), my = e.swizzle(mouseInfo, [y])
                let h = e.swizzle(resolution, [1])
                let fy = e.emit(.opFSub, type: .float, [h.id, my.id])
                return e.emit(.opCompositeConstruct, type: .float(2), [mx.id, fy.id])
            }

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
                    case .mouse: value = flippedPointer(0, 1)
                    case .mouseClick: value = flippedPointer(2, 3)
                    }
                    args.append(value.id)
                } else if let index = interface.arguments.firstIndex(where: { $0.name == param.name }) {
                    let argument = interface.arguments[index]
                    if argument.kind == .floatArray { continue }   // a compile-time handle, not a value
                    let offset = try e.convert(loadArgument(e, at: e.builder.constant(int: index * 2)), to: .int, line: line)
                    var components: [SpirvId] = []
                    for k in 0..<argument.kind.componentCount {
                        let at = e.emit(.opIAdd, type: .int, [offset.id, e.builder.constant(int: k)])
                        components.append(loadArgument(e, at: at.id).id)
                    }
                    args.append(components.count == 1 ? components[0] : e.emit(.opCompositeConstruct, type: argument.kind.type, components).id)
                } else {
                    throw PyShaderError("`\(param.name)` is not a shader input", line: line)
                }
            }

            let color = e.emit(.opFunctionCall, type: main.returnType, [main.id] + args)
            e.emit(.init(.opImageWrite, [image.id, pixel.id, color.id]))
        }
    }

    private var computeInterface: ComputeImageInterface? {
        if case .computeImage(let i) = program.target { return i }
        return nil
    }

    /// `uArgs.data[index]` as a float.
    private func loadArgument(_ e: FunctionEmitter, at index: SpirvId) -> Value {
        let buffer = argumentBufferVariable()
        let ptr = e.emit(.opAccessChain, type: .pointer(.uniform, .float), [buffer, e.builder.constant(int: 0), index])
        return e.load(ptr.id, type: .float)
    }

    private func argumentBufferVariable() -> SpirvId {
        if let v = argumentBuffer { return v }
        let interface = computeInterface!
        let arrayType = ShaderType.runtimeArray(.float)
        let arrayId = builder.type(arrayType)
        builder.decorate(arrayId, .arrayStride, [4])
        let blockType = ShaderType.structure(name: "ShaderArgs", members: [("data", arrayType)])
        let blockId = builder.type(blockType)
        builder.decorate(blockId, .bufferBlock)
        builder.memberDecorate(blockId, 0, .offset, [0])
        builder.memberDecorate(blockId, 0, .nonWritable)
        let v = builder.globalVariable(type: blockType, storage: .uniform, name: "uArgs")
        builder.decorate(v, .descriptorSet, [UInt32(interface.descriptorSet)])
        builder.decorate(v, .binding, [UInt32(interface.argumentsBinding ?? 3)])
        argumentBuffer = v
        return v
    }

    /// `len(a)` for a `FloatArray` argument.
    func argumentArrayCount(_ argument: Int, from e: FunctionEmitter, line: Int) throws -> Value {
        guard computeInterface?.argumentsBinding != nil else {
            throw PyShaderError("FloatArray arguments are only available in the compute target", line: line)
        }
        return try e.convert(loadArgument(e, at: e.builder.constant(int: argument * 2 + 1)), to: .int, line: line)
    }

    /// `a[i]` for a `FloatArray` argument: clamped to the ends, 0.0 when empty.
    func loadArgumentArrayElement(_ argument: Int, index: Value, from e: FunctionEmitter, line: Int) throws -> Value {
        guard computeInterface?.argumentsBinding != nil else {
            throw PyShaderError("FloatArray arguments are only available in the compute target", line: line)
        }
        let count = try argumentArrayCount(argument, from: e, line: line)
        let offset = try e.convert(loadArgument(e, at: e.builder.constant(int: argument * 2)), to: .int, line: line)
        let zero = e.builder.constant(int: 0)
        let last = e.emit(.opISub, type: .int, [count.id, e.builder.constant(int: 1)])
        let clamped = e.emitExt(.sClamp, type: .int, [index.id, zero, last.id])
        let at = e.emit(.opIAdd, type: .int, [offset.id, clamped.id])
        let value = loadArgument(e, at: at.id)
        let nonEmpty = e.emit(.opSGreaterThan, type: .bool, [count.id, zero])
        return e.emit(.opSelect, type: .float, [nonEmpty.id, value.id, e.builder.constant(float: 0)])
    }

    /// `layer(p)`: the view's own pixels, sampled with an explicit LOD (compute has no derivatives).
    func sampleContent(at coordinate: Value, from e: FunctionEmitter, line: Int) throws -> Value {
        guard let interface = computeInterface, let binding = interface.contentBinding else {
            throw PyShaderError("layer() needs a content image; this target does not provide one", line: line)
        }
        if contentImage == nil {
            let v = builder.globalVariable(type: .sampledImage(.sampled2D), storage: .uniformConstant, name: "uContent")
            builder.decorate(v, .descriptorSet, [UInt32(interface.descriptorSet)])
            builder.decorate(v, .binding, [UInt32(binding)])
            contentImage = v
        }
        let sampled = e.load(contentImage!, type: .sampledImage(.sampled2D))
        let lod = e.builder.constant(float: 0)
        return e.emit(.opImageSampleExplicitLod, type: .float(4), [sampled.id, coordinate.id, SpirvImageOperands.lod.rawValue, lod])
    }

    /// `return` without a value in `main` forwards the incoming `color` when it is a parameter.
    private static func forwardColor(_ emitter: FunctionEmitter, program: ShaderProgram, line: Int) throws -> Value {
        let out = program.entry.outputType
        if let color = emitter.lookupLocal("color"), color.type == out {
            return emitter.load(color.ptr, type: color.type)
        }
        throw PyShaderError("`\(program.entryPoint)` must return a `\(out)`, or take `color` as a parameter to forward it", line: line)
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
