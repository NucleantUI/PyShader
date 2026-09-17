//
//  SpirvModuleBuilder.swift
//  PyShader
//
//  Owns id allocation, the deduplicated type/constant section and the
//  logical layout of a SPIR-V module. Function bodies are appended as
//  finished instruction lists; `build()` assembles the final word stream in
//  the order the spec requires.
//

import SpirvCore

final class SpirvModuleBuilder {
    private(set) var nextId: SpirvId = 1

    private var capabilities: [SpirvCapability] = [.shader]
    private var entryPoints: [SpirvInstruction] = []
    private var executionModes: [SpirvInstruction] = []
    private var debug: [SpirvInstruction] = []
    private var annotations: [SpirvInstruction] = []
    private var declarations: [SpirvInstruction] = []   // types, constants, global variables
    private var functions: [SpirvInstruction] = []

    private var typeIds: [ShaderType: SpirvId] = [:]
    private var constantIds: [ConstantKey: SpirvId] = [:]
    /// Literal values behind scalar constant ids, so conversions of literals fold at compile time.
    private var literalInts: [SpirvId: Int] = [:]
    private var literalFloats: [SpirvId: Double] = [:]

    private(set) var glslExtId: SpirvId = 0

    private struct ConstantKey: Hashable {
        let type: ShaderType
        let words: [UInt32]
    }

    init() {
        glslExtId = allocate()
    }

    func allocate() -> SpirvId {
        defer { nextId += 1 }
        return nextId
    }

    // MARK: Capabilities / entry points / modes

    func require(_ cap: SpirvCapability) {
        if !capabilities.contains(cap) { capabilities.append(cap) }
    }

    func addEntryPoint(model: SpirvExecutionModel, function: SpirvId, name: String, interface: [SpirvId]) {
        entryPoints.append(.init(.opEntryPoint, [model.rawValue, function] + SpirvInstruction.encode(string: name) + interface))
    }

    func addExecutionMode(function: SpirvId, mode: SpirvExecutionMode, operands: [UInt32] = []) {
        executionModes.append(.init(.opExecutionMode, [function, mode.rawValue] + operands))
    }

    // MARK: Debug & annotations

    func name(_ id: SpirvId, _ name: String) {
        debug.append(.init(.opName, [id] + SpirvInstruction.encode(string: name)))
    }

    func memberName(_ structId: SpirvId, _ index: Int, _ name: String) {
        debug.append(.init(.opMemberName, [structId, UInt32(index)] + SpirvInstruction.encode(string: name)))
    }

    func decorate(_ id: SpirvId, _ decoration: SpirvDecoration, _ operands: [UInt32] = []) {
        annotations.append(.init(.opDecorate, [id, decoration.rawValue] + operands))
    }

    func memberDecorate(_ structId: SpirvId, _ index: Int, _ decoration: SpirvDecoration, _ operands: [UInt32] = []) {
        annotations.append(.init(.opMemberDecorate, [structId, UInt32(index), decoration.rawValue] + operands))
    }

    // MARK: Types

    func type(_ t: ShaderType) -> SpirvId {
        if let id = typeIds[t] { return id }
        let id: SpirvId
        switch t {
        case .void:
            id = allocate()
            declarations.append(.init(.opTypeVoid, [id]))
        case .scalar(let kind):
            id = allocate()
            switch kind {
            case .bool:
                declarations.append(.init(.opTypeBool, [id]))
            case .float(let bits):
                if bits == 16 { require(.float16) }
                declarations.append(.init(.opTypeFloat, [id, UInt32(bits)]))
            case .int(let bits, let signed):
                if bits == 16 { require(.int16) }
                declarations.append(.init(.opTypeInt, [id, UInt32(bits), signed ? 1 : 0]))
            }
        case .vector(let kind, let n):
            let elem = type(.scalar(kind))
            id = allocate()
            declarations.append(.init(.opTypeVector, [id, elem, UInt32(n)]))
        case .matrix(let kind, let cols, let rows):
            let column = type(.vector(kind, rows))
            id = allocate()
            declarations.append(.init(.opTypeMatrix, [id, column, UInt32(cols)]))
        case .array(let elem, let n):
            let elemId = type(elem)
            let length = constant(int: n)
            id = allocate()
            declarations.append(.init(.opTypeArray, [id, elemId, length]))
        case .tuple(let members):
            let memberIds = members.map { type($0) }
            id = allocate()
            declarations.append(.init(.opTypeStruct, [id] + memberIds))
            self.name(id, "tuple")
        case .structure(let name, let members):
            let memberIds = members.map { type($0.1) }
            id = allocate()
            declarations.append(.init(.opTypeStruct, [id] + memberIds))
            self.name(id, name)
            for (i, m) in members.enumerated() { memberName(id, i, m.0) }
        case .pointer(let storage, let pointee):
            let pointeeId = type(pointee)
            id = allocate()
            declarations.append(.init(.opTypePointer, [id, storage.rawValue, pointeeId]))
        case .function(let ret, let params):
            let retId = type(ret)
            let paramIds = params.map { type($0) }
            id = allocate()
            declarations.append(.init(.opTypeFunction, [id, retId] + paramIds))
        case .image(let kind):
            let sampledType = type(ShaderType.float)
            id = allocate()
            // depth 0, arrayed 0, multisampled 0; sampled: 1 = with sampler, 2 = storage
            switch kind {
            case .storage2DRgba8:
                declarations.append(.init(.opTypeImage, [id, sampledType, SpirvDim.dim2D.rawValue, 0, 0, 0, 2, SpirvImageFormat.rgba8.rawValue]))
            case .sampled2D:
                declarations.append(.init(.opTypeImage, [id, sampledType, SpirvDim.dim2D.rawValue, 0, 0, 0, 1, SpirvImageFormat.unknown.rawValue]))
            }
        case .sampledImage(let kind):
            let imageId = type(.image(kind))
            id = allocate()
            declarations.append(.init(.opTypeSampledImage, [id, imageId]))
        case .runtimeArray(let elem):
            let elemId = type(elem)
            id = allocate()
            declarations.append(.init(.opTypeRuntimeArray, [id, elemId]))
        case .floatArray:
            preconditionFailure("FloatArray handles have no SPIR-V type")
        }
        typeIds[t] = id
        return id
    }

    // MARK: Constants

    func constant(bool value: Bool) -> SpirvId {
        let t = ShaderType.bool
        let key = ConstantKey(type: t, words: [value ? 1 : 0])
        if let id = constantIds[key] { return id }
        let tid = type(t)
        let id = allocate()
        declarations.append(.init(value ? .opConstantTrue : .opConstantFalse, [tid, id]))
        constantIds[key] = id
        return id
    }

    func constant(int value: Int, type t: ShaderType = .int) -> SpirvId {
        guard case .scalar(.int(let bits, _)) = t else { preconditionFailure("constant(int:) needs an int scalar type") }
        let word: UInt32 = bits == 16
            ? UInt32(UInt16(truncatingIfNeeded: value))
            : UInt32(truncatingIfNeeded: Int32(truncatingIfNeeded: value))
        let id = scalarConstant(t, [word])
        literalInts[id] = value
        return id
    }

    func literalInt(_ id: SpirvId) -> Int? { literalInts[id] }
    func literalFloat(_ id: SpirvId) -> Double? { literalFloats[id] }

    func constant(float value: Double, type t: ShaderType = .float) -> SpirvId {
        guard case .scalar(.float(let bits)) = t else { preconditionFailure("constant(float:) needs a float scalar type") }
        let word: UInt32 = bits == 16
            ? UInt32(halfBits(Float(value)))
            : Float(value).bitPattern
        let id = scalarConstant(t, [word])
        literalFloats[id] = value
        return id
    }

    private func scalarConstant(_ t: ShaderType, _ words: [UInt32]) -> SpirvId {
        let key = ConstantKey(type: t, words: words)
        if let id = constantIds[key] { return id }
        let tid = type(t)
        let id = allocate()
        declarations.append(.init(.opConstant, [tid, id] + words))
        constantIds[key] = id
        return id
    }

    func constantComposite(type t: ShaderType, elements: [SpirvId]) -> SpirvId {
        let key = ConstantKey(type: t, words: elements)
        if let id = constantIds[key] { return id }
        let tid = type(t)
        let id = allocate()
        declarations.append(.init(.opConstantComposite, [tid, id] + elements))
        constantIds[key] = id
        return id
    }

    /// Zero of any scalar or vector type.
    func zero(of t: ShaderType) -> SpirvId {
        switch t {
        case .scalar(.bool): return constant(bool: false)
        case .scalar(.float): return constant(float: 0, type: t)
        case .scalar(.int): return constant(int: 0, type: t)
        case .vector(let k, let n):
            let z = zero(of: .scalar(k))
            return constantComposite(type: t, elements: Array(repeating: z, count: n))
        case .matrix(let k, let cols, let rows):
            let z = zero(of: .vector(k, rows))
            return constantComposite(type: t, elements: Array(repeating: z, count: cols))
        case .array(let elem, let n):
            let z = zero(of: elem)
            return constantComposite(type: t, elements: Array(repeating: z, count: n))
        case .tuple(let members):
            return constantComposite(type: t, elements: members.map { zero(of: $0) })
        default: preconditionFailure("zero(of:) on non-numeric type \(t)")
        }
    }

    // MARK: Global variables

    func globalVariable(type t: ShaderType, storage: SpirvStorageClass, name: String? = nil) -> SpirvId {
        let ptr = type(.pointer(storage, t))
        let id = allocate()
        declarations.append(.init(.opVariable, [ptr, id, storage.rawValue]))
        if let name { self.name(id, name) }
        return id
    }

    // MARK: Functions

    func addFunction(_ body: [SpirvInstruction]) {
        functions.append(contentsOf: body)
    }

    // MARK: Assembly

    func build() -> [UInt32] {
        var words: [UInt32] = [
            0x0723_0203,        // magic
            0x0001_0000,        // SPIR-V 1.0
            0x5079_5348,        // generator: "PySH"
            nextId,             // bound
            0,                  // schema
        ]
        for cap in capabilities {
            words += SpirvInstruction(.opCapability, [cap.rawValue]).words
        }
        words += SpirvInstruction(.opExtInstImport, [glslExtId] + SpirvInstruction.encode(string: "GLSL.std.450")).words
        words += SpirvInstruction(.opMemoryModel, [SpirvAddressingModel.logical.rawValue, SpirvMemoryModel.glsl450.rawValue]).words
        for i in entryPoints { words += i.words }
        for i in executionModes { words += i.words }
        words += SpirvInstruction(.opSource, [SpirvSourceLanguage.unknown.rawValue, 0]).words
        for i in debug { words += i.words }
        for i in annotations { words += i.words }
        for i in declarations { words += i.words }
        for i in functions { words += i.words }
        return words
    }
}
