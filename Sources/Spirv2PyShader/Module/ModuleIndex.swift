//
//  ModuleIndex.swift
//  Spirv2PyShader
//
//  The module-level view of a SPIR-V word stream: types as `ShaderType`,
//  constants, names, decorations, global variables, entry points and every
//  function split into its basic blocks. Instructions the decompiler does
//  not understand are kept as raw opcodes so the function decompiler can
//  report them where they are used.
//

import PyShader
import SpirvCore

typealias Instruction = SpirvModuleReader.Instruction

/// A constant's value, as far as the decompiler needs it.
indirect enum ConstantValue {
    case bool(Bool)
    /// Wide enough for a `uint` on 32-bit hosts (wasm).
    case int(Int64)
    case float(Double)
    case composite([SpirvId])
    /// `OpConstantNull`: zero of the type.
    case null
    /// `OpUndef`: any value will do.
    case undefined
}

struct Constant {
    let type: ShaderType
    let value: ConstantValue
}

struct GlobalVariable {
    let id: SpirvId
    /// The pointee type.
    let type: ShaderType
    let storage: SpirvStorageClass
    let name: String?
    /// The constant it starts as, when the module says.
    let initializer: SpirvId?
}

struct EntryPoint {
    let model: UInt32
    let function: SpirvId
    let name: String
    let interface: [SpirvId]
}

struct Block {
    let label: SpirvId
    /// Everything after `OpLabel`, terminator included.
    var instructions: [Instruction]

    var terminator: Instruction { instructions[instructions.count - 1] }

    /// The `OpLoopMerge` / `OpSelectionMerge` just before the terminator, if any.
    var merge: Instruction? {
        guard instructions.count >= 2 else { return nil }
        let m = instructions[instructions.count - 2]
        return m.op == .opLoopMerge || m.op == .opSelectionMerge ? m : nil
    }

    /// The instructions before the merge/terminator.
    var body: ArraySlice<Instruction> {
        instructions.dropLast(merge == nil ? 1 : 2)
    }

    var phis: [Instruction] {
        instructions.prefix { $0.op == .opPhi }
    }
}

struct FunctionDef {
    let id: SpirvId
    let returnType: ShaderType
    let functionType: ShaderType
    var params: [(id: SpirvId, type: ShaderType)]
    var blocks: [Block]
    var blockIndex: [SpirvId: Int]

    func block(_ label: SpirvId) -> Block? {
        blockIndex[label].map { blocks[$0] }
    }

    var allInstructions: [Instruction] { blocks.flatMap(\.instructions) }
}

final class ModuleIndex {
    let reader: SpirvModuleReader
    private(set) var types: [SpirvId: ShaderType] = [:]
    /// Types the decompiler cannot express (`OpTypeSampler` and friends), by the SPIR-V spelling.
    private(set) var opaqueTypes: [SpirvId: String] = [:]
    private(set) var constants: [SpirvId: Constant] = [:]
    private(set) var names: [SpirvId: String] = [:]
    private(set) var memberNames: [SpirvId: [Int: String]] = [:]
    private(set) var decorations: [SpirvId: [(decoration: UInt32, operands: [UInt32])]] = [:]
    private(set) var memberDecorations: [SpirvId: [(member: Int, decoration: UInt32, operands: [UInt32])]] = [:]
    private(set) var globals: [SpirvId: GlobalVariable] = [:]
    /// Globals in declaration order.
    private(set) var globalOrder: [SpirvId] = []
    private(set) var entryPoints: [EntryPoint] = []
    private(set) var extInstImports: [SpirvId: String] = [:]
    private(set) var functions: [FunctionDef] = []
    private(set) var functionIndex: [SpirvId: Int] = [:]
    private(set) var sourceLanguage: UInt32?

    init(reader: SpirvModuleReader) throws {
        self.reader = reader
        try index()
    }

    func function(_ id: SpirvId) -> FunctionDef? {
        functionIndex[id].map { functions[$0] }
    }

    func decoration(_ id: SpirvId, _ d: SpirvDecoration) -> [UInt32]? {
        decorations[id]?.first { $0.decoration == d.rawValue }?.operands
    }

    func has(_ id: SpirvId, _ d: SpirvDecoration) -> Bool {
        decoration(id, d) != nil
    }

    func memberDecoration(_ id: SpirvId, member: Int, _ d: SpirvDecoration) -> [UInt32]? {
        memberDecorations[id]?.first { $0.member == member && $0.decoration == d.rawValue }?.operands
    }

    /// The generator word as `"<vendor id> v<version>"`.
    var generatorDescription: String {
        let vendor = reader.generator >> 16
        let version = reader.generator & 0xFFFF
        if reader.generator == 0x5079_5348 { return "PyShader" }
        switch vendor {
        case 8: return "glslang \(version)"
        case 24: return "naga \(version)"
        case 21: return "clspv \(version)"
        default: return "generator \(vendor) v\(version)"
        }
    }

    // MARK: - Indexing

    private func index() throws {
        var current: FunctionDef?
        var blocks: [Block] = []
        var open: Block?

        func finishBlock() {
            if let b = open { blocks.append(b) }
            open = nil
        }

        for inst in reader.instructions {
            guard let op = inst.op else {
                if current != nil, open != nil {
                    // Unknown opcode inside a function: keep it, the function decompiler reports it.
                    open!.instructions.append(inst)
                }
                continue
            }
            switch op {
            case .opSource:
                sourceLanguage = inst.operands.first
            case .opName:
                names[inst.operands[0]] = inst.string(at: 1).string
            case .opMemberName:
                memberNames[inst.operands[0], default: [:]][Int(inst.operands[1])] = inst.string(at: 2).string
            case .opDecorate:
                decorations[inst.operands[0], default: []].append((inst.operands[1], Array(inst.operands.dropFirst(2))))
            case .opMemberDecorate:
                memberDecorations[inst.operands[0], default: []].append((Int(inst.operands[1]), inst.operands[2], Array(inst.operands.dropFirst(3))))
            case .opExtInstImport:
                extInstImports[inst.operands[0]] = inst.string(at: 1).string
            case .opEntryPoint:
                let (name, count) = inst.string(at: 2)
                entryPoints.append(.init(model: inst.operands[0], function: inst.operands[1], name: name, interface: Array(inst.operands.dropFirst(2 + count))))

            case .opTypeVoid, .opTypeBool, .opTypeInt, .opTypeFloat, .opTypeVector, .opTypeMatrix, .opTypeArray,
                 .opTypeRuntimeArray, .opTypeStruct, .opTypePointer, .opTypeFunction, .opTypeImage, .opTypeSampledImage,
                 .opTypeSampler, .opTypeOpaque:
                try indexType(inst, op)

            case .opConstantTrue, .opSpecConstantTrue:
                constants[inst.operands[1]] = .init(type: try type(inst.operands[0]), value: .bool(true))
            case .opConstantFalse, .opSpecConstantFalse:
                constants[inst.operands[1]] = .init(type: try type(inst.operands[0]), value: .bool(false))
            case .opConstant, .opSpecConstant:
                let t = try type(inst.operands[0])
                constants[inst.operands[1]] = .init(type: t, value: try scalarValue(t, words: Array(inst.operands.dropFirst(2)), at: inst))
            case .opConstantComposite, .opSpecConstantComposite:
                constants[inst.operands[1]] = .init(type: try type(inst.operands[0]), value: .composite(Array(inst.operands.dropFirst(2))))
            case .opConstantNull:
                constants[inst.operands[1]] = .init(type: try type(inst.operands[0]), value: .null)
            case .opUndef where current == nil:
                constants[inst.operands[1]] = .init(type: try type(inst.operands[0]), value: .undefined)

            case .opVariable where current == nil:
                guard case .pointer(let storage, let pointee) = try type(inst.operands[0]) else {
                    throw Spirv2PyShaderError("global %\(inst.operands[1]) has a non-pointer type")
                }
                globals[inst.operands[1]] = .init(id: inst.operands[1], type: pointee, storage: storage, name: names[inst.operands[1]],
                                                  initializer: inst.operands.count > 3 ? inst.operands[3] : nil)
                globalOrder.append(inst.operands[1])

            case .opFunction:
                let fnType = try type(inst.operands[3])
                current = FunctionDef(id: inst.operands[1], returnType: try type(inst.operands[0]), functionType: fnType, params: [], blocks: [], blockIndex: [:])
                blocks = []
            case .opFunctionParameter:
                current?.params.append((inst.operands[1], try type(inst.operands[0])))
            case .opLabel:
                finishBlock()
                open = Block(label: inst.operands[0], instructions: [])
            case .opFunctionEnd:
                finishBlock()
                guard var fn = current else { throw Spirv2PyShaderError("OpFunctionEnd outside a function") }
                fn.blocks = blocks
                for (i, b) in blocks.enumerated() { fn.blockIndex[b.label] = i }
                functionIndex[fn.id] = functions.count
                functions.append(fn)
                current = nil
            case .opLine, .opNoLine:
                break
            default:
                if current != nil, open != nil {
                    open!.instructions.append(inst)
                }
            }
        }
    }

    private func type(_ id: SpirvId) throws -> ShaderType {
        if let t = types[id] { return t }
        if let name = opaqueTypes[id] { throw Spirv2PyShaderError("\(name) (%\(id)) has no PyShader equivalent") }
        throw Spirv2PyShaderError("%\(id) is not a type")
    }

    private func indexType(_ inst: Instruction, _ op: SpirvOp) throws {
        let id = inst.operands[0]
        let t: ShaderType
        switch op {
        case .opTypeVoid:
            t = .void
        case .opTypeBool:
            t = .bool
        case .opTypeInt:
            let bits = Int(inst.operands[1])
            guard bits == 32 || bits == 16 else { throw Spirv2PyShaderError("\(bits)-bit integers are not available in PyShader") }
            t = .scalar(.int(bits: bits, signed: inst.operands[2] == 1))
        case .opTypeFloat:
            let bits = Int(inst.operands[1])
            guard bits == 32 || bits == 16 else { throw Spirv2PyShaderError("\(bits)-bit floats are not available in PyShader") }
            t = .scalar(.float(bits: bits))
        case .opTypeVector:
            guard let k = try type(inst.operands[1]).scalarKind else { throw Spirv2PyShaderError("vector %\(id) of a non-scalar") }
            t = .vector(k, Int(inst.operands[2]))
        case .opTypeMatrix:
            guard case .vector(let k, let rows) = try type(inst.operands[1]) else { throw Spirv2PyShaderError("matrix %\(id) of non-vector columns") }
            t = .matrix(k, columns: Int(inst.operands[2]), rows: rows)
        case .opTypeArray:
            guard let length = constants[inst.operands[2]], case .int(let n) = length.value else {
                throw Spirv2PyShaderError("array %\(id) has a non-constant length")
            }
            t = .array(try type(inst.operands[1]), Int(n))
        case .opTypeRuntimeArray:
            t = .runtimeArray(try type(inst.operands[1]))
        case .opTypeStruct:
            let members = try inst.operands.dropFirst().enumerated().map { i, m in
                (memberNames[id]?[i] ?? "m\(i)", try type(m))
            }
            let name = names[id]
            if name == "tuple" {
                t = .tuple(members.map(\.1))
            } else {
                t = .structure(name: name ?? "Struct\(id)", members: members)
            }
        case .opTypePointer:
            guard let storage = SpirvStorageClass(rawValue: inst.operands[1]) else {
                throw Spirv2PyShaderError("storage class \(inst.operands[1]) is not supported")
            }
            if let name = opaqueTypes[inst.operands[2]] {
                opaqueTypes[id] = "pointer to \(name)"
                return
            }
            t = .pointer(storage, try type(inst.operands[2]))
        case .opTypeFunction:
            let ret = try type(inst.operands[1])
            var params: [ShaderType] = []
            for p in inst.operands.dropFirst(2) {
                if let name = opaqueTypes[p] {
                    opaqueTypes[id] = "function taking \(name)"
                    return
                }
                params.append(try type(p))
            }
            t = .function(returns: ret, params: params)
        case .opTypeImage:
            // sampled: 1 = with a sampler, 2 = storage
            t = .image(inst.operands[6] == 2 ? .storage2DRgba8 : .sampled2D)
        case .opTypeSampledImage:
            guard case .image(let kind) = try type(inst.operands[1]) else { throw Spirv2PyShaderError("sampled image %\(id) of a non-image") }
            t = .sampledImage(kind)
        case .opTypeSampler:
            opaqueTypes[id] = "OpTypeSampler"
            return
        case .opTypeOpaque:
            opaqueTypes[id] = "OpTypeOpaque \(inst.string(at: 1).string)"
            return
        default:
            preconditionFailure()
        }
        types[id] = t
    }

    private func scalarValue(_ t: ShaderType, words: [UInt32], at inst: Instruction) throws -> ConstantValue {
        guard let w = words.first else { throw Spirv2PyShaderError("constant at word \(inst.offset) has no value") }
        switch t {
        case .scalar(.float(let bits)):
            return .float(Double(bits == 16 ? floatFromHalfBits(UInt16(truncatingIfNeeded: w)) : Float(bitPattern: w)))
        case .scalar(.int(let bits, let signed)):
            if bits == 16 {
                return .int(signed ? Int64(Int16(truncatingIfNeeded: w)) : Int64(UInt16(truncatingIfNeeded: w)))
            }
            return .int(signed ? Int64(Int32(bitPattern: w)) : Int64(w))
        default:
            throw Spirv2PyShaderError("constant at word \(inst.offset) of non-scalar type `\(t)`")
        }
    }
}
