//
//  SpirvModule.swift
//  Spirv2GLSL
//
//  A SPIR-V module read into what a translator looks things up by: the
//  types, constants, names and decorations by id, the module variables, the
//  entry points and the functions as blocks, each instruction with the
//  source line an `OpLine` before it named.
//

import SpirvCore

/// A SPIR-V type, as the translator needs it.
indirect enum SpirvType: Equatable {
    case void
    case bool
    case int(width: Int, signed: Bool)
    case float(width: Int)
    case vector(SpirvType, Int)
    /// `columns` column vectors of type `column`.
    case matrix(column: SpirvType, columns: Int)
    /// An array of `length` elements; nil for a runtime array.
    case array(SpirvType, length: Int?)
    /// The struct declared at `id`.
    case structure(SpirvId)
    case pointer(storage: UInt32, pointee: SpirvType)
    case function(returns: SpirvType, params: [SpirvType])
    case image(dim: UInt32, depth: UInt32, arrayed: UInt32, multisampled: UInt32, sampled: UInt32)
    case sampledImage(dim: UInt32)
    case sampler

    var isScalar: Bool {
        switch self {
        case .bool, .int, .float: return true
        default: return false
        }
    }

    /// The scalar type of a scalar, vector or matrix.
    var scalar: SpirvType? {
        switch self {
        case .bool, .int, .float: return self
        case .vector(let c, _): return c
        case .matrix(let column, _): return column.scalar
        default: return nil
        }
    }

    /// Components of a vector, 1 for a scalar.
    var componentCount: Int {
        if case .vector(_, let n) = self { return n }
        return 1
    }

    var isFloat: Bool { if case .float? = scalar { return true }; return false }
    var isInt: Bool { if case .int? = scalar { return true }; return false }
    var isBool: Bool { if case .bool? = scalar { return true }; return false }
}

/// A constant: a scalar's bits, a composite of other constants, a null or an undefined value.
enum SpirvConstant {
    case scalar([UInt32])
    case bool(Bool)
    case composite([SpirvId])
    case null
    case undef
}

/// An instruction with the source line it came from.
struct Located {
    let inst: SpirvModuleReader.Instruction
    /// The `OpString` id and line of the `OpLine` before it, if any.
    let file: SpirvId?
    let line: Int?

    var op: SpirvOp? { inst.op }
    var operands: [UInt32] { inst.operands }
}

struct SpirvBlock {
    let label: SpirvId
    /// Its instructions, merge and terminator included; the `OpLabel` not.
    var body: [Located]
    /// `OpSelectionMerge` / `OpLoopMerge`, if the block has one.
    var merge: Located? {
        guard body.count >= 2 else { return nil }
        let m = body[body.count - 2]
        return (m.op == .opSelectionMerge || m.op == .opLoopMerge) ? m : nil
    }
    var terminator: Located { body[body.count - 1] }
    /// The instructions before the merge and terminator.
    var instructions: ArraySlice<Located> { body.dropLast(merge == nil ? 1 : 2) }
}

struct SpirvFunction {
    let id: SpirvId
    let returnType: SpirvId
    let functionType: SpirvId
    var params: [(id: SpirvId, type: SpirvId)] = []
    var blocks: [SpirvBlock] = []
    let located: Located
}

struct SpirvGlobal {
    let id: SpirvId
    /// The pointer type.
    let type: SpirvId
    let storage: UInt32
    let initializer: SpirvId?
}

struct SpirvEntryPoint {
    let model: UInt32
    let function: SpirvId
    let name: String
    let interface: [SpirvId]
}

final class SpirvModule {
    let reader: SpirvModuleReader
    private(set) var names: [SpirvId: String] = [:]
    private(set) var memberNames: [SpirvId: [Int: String]] = [:]
    /// Decoration → its literal operands, by target id.
    private(set) var decorations: [SpirvId: [UInt32: [UInt32]]] = [:]
    private(set) var memberDecorations: [SpirvId: [Int: [UInt32: [UInt32]]]] = [:]
    private(set) var types: [SpirvId: SpirvType] = [:]
    /// Member type ids, by struct id.
    private(set) var structMembers: [SpirvId: [SpirvId]] = [:]
    private(set) var constants: [SpirvId: (type: SpirvId, value: SpirvConstant)] = [:]
    /// Constants that are spec constants: the value read is their default.
    private(set) var specConstants: Set<SpirvId> = []
    private(set) var globals: [SpirvId: SpirvGlobal] = [:]
    private(set) var globalOrder: [SpirvId] = []
    private(set) var functions: [SpirvId: SpirvFunction] = [:]
    private(set) var functionOrder: [SpirvId] = []
    private(set) var entryPoints: [SpirvEntryPoint] = []
    /// Execution modes and their literals, by entry point function.
    private(set) var executionModes: [SpirvId: [UInt32: [UInt32]]] = [:]
    private(set) var strings: [SpirvId: String] = [:]
    /// The `GLSL.std.450` import, and every other one by id with its name.
    private(set) var glslStd450: SpirvId?
    private(set) var otherImports: [SpirvId: String] = [:]
    private(set) var capabilities: Set<UInt32> = []

    init(words: [UInt32]) throws {
        reader = try SpirvModuleReader(words: words)
        try read()
    }

    // MARK: Lookups

    func type(_ id: SpirvId) throws -> SpirvType {
        guard let t = types[id] else { throw Spirv2GLSLError("id %\(id) is not a type") }
        return t
    }

    func decoration(_ id: SpirvId, _ d: SpirvDecoration) -> [UInt32]? {
        decorations[id]?[d.rawValue]
    }

    func memberDecoration(_ id: SpirvId, _ member: Int, _ d: SpirvDecoration) -> [UInt32]? {
        memberDecorations[id]?[member]?[d.rawValue]
    }

    func members(of structId: SpirvId) throws -> [SpirvType] {
        try (structMembers[structId] ?? []).map { try type($0) }
    }

    /// The integer value of a constant (an array length, a constant index).
    func intConstant(_ id: SpirvId) -> Int? {
        guard let c = constants[id], case .scalar(let words) = c.value, let t = types[c.type] else { return nil }
        switch t {
        case .int(let width, let signed):
            // Int(exactly:): Int is 32 bits on wasm32, where a larger value has no Int.
            if width == 64, words.count >= 2 {
                let v = UInt64(words[0]) | UInt64(words[1]) << 32
                return signed ? Int(exactly: Int64(bitPattern: v)) : Int(exactly: v)
            }
            return signed ? Int(Int32(bitPattern: words[0])) : Int(exactly: words[0])
        default:
            return nil
        }
    }

    // MARK: Reading

    private func read() throws {
        var currentFunction: SpirvFunction?
        var currentBlock: SpirvBlock?
        var file: SpirvId?
        var line: Int?

        func closeBlock() {
            if let b = currentBlock { currentFunction?.blocks.append(b) }
            currentBlock = nil
        }

        for inst in reader.instructions {
            let o = inst.operands
            guard let op = inst.op else {
                if currentBlock != nil {
                    throw Spirv2GLSLError("unknown opcode \(inst.opcode) in a function", file: file.flatMap { strings[$0] }, line: line)
                }
                continue
            }
            switch op {
            case .opLine:
                file = o[0]; line = Int(o[1]); continue
            case .opNoLine:
                file = nil; line = nil; continue
            default:
                break
            }
            let located = Located(inst: inst, file: file, line: line)

            if currentFunction != nil {
                switch op {
                case .opFunctionParameter:
                    currentFunction!.params.append((o[1], o[0]))
                case .opLabel:
                    closeBlock()
                    currentBlock = SpirvBlock(label: o[0], body: [])
                case .opFunctionEnd:
                    closeBlock()
                    let f = currentFunction!
                    functions[f.id] = f
                    functionOrder.append(f.id)
                    currentFunction = nil
                default:
                    currentBlock?.body.append(located)
                }
                continue
            }

            switch op {
            case .opCapability:
                capabilities.insert(o[0])
            case .opExtInstImport:
                let name = inst.string(at: 1).string
                if name == "GLSL.std.450" { glslStd450 = o[0] } else { otherImports[o[0]] = name }
            case .opEntryPoint:
                let (name, count) = inst.string(at: 2)
                entryPoints.append(SpirvEntryPoint(model: o[0], function: o[1], name: name, interface: Array(o[(2 + count)...])))
            case .opExecutionMode, .opExecutionModeId:
                executionModes[o[0], default: [:]][o[1]] = Array(o.dropFirst(2))
            case .opString:
                strings[o[0]] = inst.string(at: 1).string
            case .opName:
                names[o[0]] = inst.string(at: 1).string
            case .opMemberName:
                memberNames[o[0], default: [:]][Int(o[1])] = inst.string(at: 2).string
            case .opDecorate:
                decorations[o[0], default: [:]][o[1]] = Array(o.dropFirst(2))
            case .opMemberDecorate:
                memberDecorations[o[0], default: [:]][Int(o[1]), default: [:]][o[2]] = Array(o.dropFirst(3))
            case .opTypeVoid: types[o[0]] = .void
            case .opTypeBool: types[o[0]] = .bool
            case .opTypeInt: types[o[0]] = .int(width: Int(o[1]), signed: o[2] != 0)
            case .opTypeFloat: types[o[0]] = .float(width: Int(o[1]))
            case .opTypeVector: types[o[0]] = .vector(try type(o[1]), Int(o[2]))
            case .opTypeMatrix: types[o[0]] = .matrix(column: try type(o[1]), columns: Int(o[2]))
            case .opTypeArray:
                guard let n = intConstant(o[2]) else {
                    throw Spirv2GLSLError("array length %\(o[2]) is not an integer constant", file: file.flatMap { strings[$0] }, line: line)
                }
                types[o[0]] = .array(try type(o[1]), length: n)
            case .opTypeRuntimeArray: types[o[0]] = .array(try type(o[1]), length: nil)
            case .opTypeStruct:
                types[o[0]] = .structure(o[0])
                structMembers[o[0]] = Array(o.dropFirst())
            case .opTypePointer:
                // A forward-declared pointee (OpTypeForwardPointer) is not a type yet.
                types[o[0]] = .pointer(storage: o[1], pointee: types[o[2]] ?? .void)
            case .opTypeFunction:
                types[o[0]] = .function(returns: try type(o[1]), params: try o.dropFirst(2).map { try type($0) })
            case .opTypeImage:
                types[o[0]] = .image(dim: o[2], depth: o[3], arrayed: o[4], multisampled: o[5], sampled: o[6])
            case .opTypeSampledImage:
                guard case .image(let dim, _, _, _, _) = try type(o[1]) else {
                    throw Spirv2GLSLError("OpTypeSampledImage of a non-image")
                }
                types[o[0]] = .sampledImage(dim: dim)
            case .opTypeSampler: types[o[0]] = .sampler
            case .opConstant, .opSpecConstant:
                constants[o[1]] = (o[0], .scalar(Array(o.dropFirst(2))))
                if op == .opSpecConstant { specConstants.insert(o[1]) }
            case .opConstantTrue, .opSpecConstantTrue:
                constants[o[1]] = (o[0], .bool(true))
                if op == .opSpecConstantTrue { specConstants.insert(o[1]) }
            case .opConstantFalse, .opSpecConstantFalse:
                constants[o[1]] = (o[0], .bool(false))
                if op == .opSpecConstantFalse { specConstants.insert(o[1]) }
            case .opConstantComposite, .opSpecConstantComposite:
                constants[o[1]] = (o[0], .composite(Array(o.dropFirst(2))))
                if op == .opSpecConstantComposite { specConstants.insert(o[1]) }
            case .opConstantNull:
                constants[o[1]] = (o[0], .null)
            case .opUndef:
                constants[o[1]] = (o[0], .undef)
            case .opSpecConstantOp:
                throw Spirv2GLSLError("OpSpecConstantOp has no OpenGL ES 2 equivalent: specialize the module first", file: file.flatMap { strings[$0] }, line: line)
            case .opVariable:
                let storage = o[2]
                globals[o[1]] = SpirvGlobal(id: o[1], type: o[0], storage: storage, initializer: o.count > 3 ? o[3] : nil)
                globalOrder.append(o[1])
            case .opFunction:
                currentFunction = SpirvFunction(id: o[1], returnType: o[0], functionType: o[3], located: located)
            default:
                // OpSource, OpMemoryModel, OpModuleProcessed, OpSourceExtension, OpExtension, …
                break
            }
        }
    }
}
