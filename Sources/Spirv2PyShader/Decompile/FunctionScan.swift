//
//  FunctionScan.swift
//  Spirv2PyShader
//
//  Facts about one function gathered before it is decompiled: which
//  operands are ids (for use counts), which variable every pointer is
//  rooted in, what is loaded, stored and called.
//

import PyShader
import SpirvCore

/// Whether an instruction has a result id (and a result type in operand 0).
func hasResult(_ op: SpirvOp) -> Bool {
    switch op {
    case .opStore, .opCopyMemory, .opBranch, .opBranchConditional, .opSwitch, .opReturn, .opReturnValue, .opKill,
         .opUnreachable, .opLoopMerge, .opSelectionMerge, .opLabel, .opFunctionEnd, .opImageWrite, .opNop, .opLine, .opNoLine:
        return false
    default:
        return true
    }
}

/// The operands of an instruction that are ids of values or pointers (not
/// the result type, the result, literals, or the callee of a call).
func valueOperands(_ inst: Instruction) -> [SpirvId] {
    guard let op = inst.op else { return [] }
    let ops = inst.operands
    switch op {
    case .opLoad: return [ops[2]]
    case .opStore: return [ops[0], ops[1]]
    case .opCopyMemory: return [ops[0], ops[1]]
    case .opAccessChain, .opInBoundsAccessChain: return Array(ops[2...])
    case .opFunctionCall: return Array(ops[3...])
    case .opExtInst: return Array(ops[4...])
    case .opCompositeExtract: return [ops[2]]
    case .opCompositeInsert: return [ops[2], ops[3]]
    case .opVectorShuffle: return [ops[2], ops[3]]
    case .opPhi: return stride(from: 2, to: ops.count, by: 2).map { ops[$0] }
    case .opBranchConditional: return [ops[0]]
    case .opSwitch: return [ops[0]]
    case .opReturnValue: return [ops[0]]
    case .opVariable: return ops.count > 3 ? [ops[3]] : []
    case .opImageSampleImplicitLod, .opImageSampleExplicitLod, .opImageSampleDrefImplicitLod, .opImageSampleDrefExplicitLod,
         .opImageFetch, .opImageGather, .opImageRead:
        // image, coordinate, (dref), operands mask, then ids
        var ids = [ops[2], ops[3]]
        var i = 4
        if op == .opImageSampleDrefImplicitLod || op == .opImageSampleDrefExplicitLod || op == .opImageGather { ids.append(ops[4]); i = 5 }
        if ops.count > i + 1 { ids += ops[(i + 1)...] }
        return ids
    case .opImageWrite: return [ops[0], ops[1], ops[2]]
    case .opFunction, .opFunctionParameter, .opLabel, .opReturn, .opKill, .opUnreachable, .opLoopMerge, .opSelectionMerge,
         .opBranch, .opFunctionEnd, .opNop, .opLine, .opNoLine, .opUndef:
        return []
    default:
        return hasResult(op) ? Array(ops.dropFirst(2)) : ops
    }
}

struct FunctionScan {
    let function: FunctionDef
    /// Result id -> defining instruction.
    private(set) var defs: [SpirvId: Instruction] = [:]
    /// Result id -> its type.
    private(set) var resultTypes: [SpirvId: ShaderType] = [:]
    /// Pointer id (variable, pointer parameter, access chain) -> the variable it is rooted in.
    private(set) var roots: [SpirvId: SpirvId] = [:]
    /// Access chain id -> its first index as a constant, when the root is a block.
    private(set) var firstMember: [SpirvId: Int] = [:]
    private(set) var useCounts: [SpirvId: Int] = [:]
    private(set) var users: [SpirvId: [Instruction]] = [:]
    /// Roots read by an `OpLoad` (through any chain).
    private(set) var loadedRoots: Set<SpirvId> = []
    /// Roots written by an `OpStore` (through any chain).
    private(set) var storedRoots: Set<SpirvId> = []
    private(set) var calls: [Instruction] = []
    /// Pointer parameters of this function.
    private(set) var pointerParams: Set<SpirvId> = []

    init(function: FunctionDef, module: ModuleIndex) {
        self.function = function
        for p in function.params where p.type.isPointer {
            pointerParams.insert(p.id)
            roots[p.id] = p.id
        }
        for g in module.globalOrder { roots[g] = g }

        for inst in function.allInstructions {
            guard let op = inst.op else { continue }
            if hasResult(op), inst.operands.count >= 2 {
                defs[inst.operands[1]] = inst
                if let t = module.types[inst.operands[0]] { resultTypes[inst.operands[1]] = t }
            }
            var operands = valueOperands(inst)
            // `v.xyz` shuffles the vector with itself: one use.
            if op == .opVectorShuffle, operands.count == 2, operands[0] == operands[1] { operands.removeLast() }
            for id in operands {
                useCounts[id, default: 0] += 1
                users[id, default: []].append(inst)
            }
            switch op {
            case .opVariable:
                roots[inst.operands[1]] = inst.operands[1]
            case .opAccessChain, .opInBoundsAccessChain:
                let base = inst.operands[2]
                roots[inst.operands[1]] = roots[base] ?? base
                if inst.operands.count > 3, roots[base] == base, module.globals[base] != nil,
                   let c = module.constants[inst.operands[3]], case .int(let k) = c.value {
                    firstMember[inst.operands[1]] = Int(k)
                } else if let m = firstMember[base] {
                    firstMember[inst.operands[1]] = m
                }
            case .opLoad:
                if let r = roots[inst.operands[2]] { loadedRoots.insert(r) }
            case .opStore:
                if let r = roots[inst.operands[0]] { storedRoots.insert(r) }
            case .opFunctionCall:
                calls.append(inst)
            default:
                break
            }
        }
    }

    func root(_ pointer: SpirvId) -> SpirvId? { roots[pointer] }
}

extension ShaderType {
    var isPointer: Bool {
        if case .pointer = self { return true }
        return false
    }

    var pointee: ShaderType? {
        if case .pointer(_, let t) = self { return t }
        return nil
    }
}
