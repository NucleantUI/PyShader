//
//  CountingLoops.swift
//  Spirv2GLSL
//
//  A loop GLSL ES 1.00 runs everywhere has Appendix A's form: an int or
//  float index from a constant, a test against a constant, a step of a
//  constant, nothing else changing the index. A SPIR-V loop of that shape
//  over a function variable — the test the header (or a straight chain of
//  blocks after it) branches on, the continue block adding the step — is
//  written as such a `for`, its own index standing in for the variable's
//  reads in the body. The variable itself still steps in the continue
//  construct, so it holds what the module says it does after the loop.
//
//      i = 1;                                   // the store before the loop
//      for (int i_2 = 1; i_2 < 9; i_2 += 2) {   // header: i < 9; continue: i += 2
//          ... i_2 ...
//          i = i_2 + 2;
//      }
//

import SpirvCore

struct CountingLoop {
    let counter: SpirvId
    let isFloat: Bool
    let start: String
    let comparison: String
    let bound: String
    /// The step's literal, without its sign, and whether it counts up.
    let stepLiteral: String
    let up: Bool
    let bodyStart: SpirvId
    /// The block whose branch enters the body.
    let testBlock: SpirvId

    func step(_ index: String) -> String {
        if stepLiteral == "1" { return up ? "\(index)++" : "\(index)--" }
        return "\(index) \(up ? "+=" : "-=") \(stepLiteral)"
    }
}

extension FunctionWriter {
    private static let comparisons: [SpirvOp: String] = [
        .opSLessThan: "<", .opSLessThanEqual: "<=", .opSGreaterThan: ">", .opSGreaterThanEqual: ">=",
        .opULessThan: "<", .opULessThanEqual: "<=", .opUGreaterThan: ">", .opUGreaterThanEqual: ">=",
        .opIEqual: "==", .opINotEqual: "!=",
        .opFOrdLessThan: "<", .opFOrdLessThanEqual: "<=", .opFOrdGreaterThan: ">", .opFOrdGreaterThanEqual: ">=",
        .opFUnordLessThan: "<", .opFUnordLessThanEqual: "<=", .opFUnordGreaterThan: ">", .opFUnordGreaterThanEqual: ">=",
        .opFOrdEqual: "==", .opFOrdNotEqual: "!=", .opFUnordEqual: "==", .opFUnordNotEqual: "!=",
    ]
    private static let negated = ["<": ">=", "<=": ">", ">": "<=", ">=": "<", "==": "!=", "!=": "=="]
    private static let swapped = ["<": ">", "<=": ">=", ">": "<", ">=": "<=", "==": "==", "!=": "!="]

    /// The loop at `header` as a counting loop, or nil when it is not one.
    func countingLoop(_ header: SpirvBlock) throws -> CountingLoop? {
        guard let m = header.merge, m.op == .opLoopMerge else { return nil }
        let merge = m.operands[0], cont = m.operands[1]
        guard cont != header.label, !hasPhis(header.label), !hasPhis(merge), !hasPhis(cont) else { return nil }

        // The test: the header, or the end of a straight chain of empty blocks after it.
        var test = header
        while test.terminator.op == .opBranch, test.instructions.isEmpty {
            let next = test.terminator.operands[0]
            guard next != merge, next != cont, next != header.label else { return nil }
            test = try block(next)
            guard test.merge == nil, !hasPhis(test.label) else { return nil }
        }
        guard test.terminator.op == .opBranchConditional else { return nil }
        let ti = Array(test.instructions)
        guard ti.count == 2, ti[0].op == .opLoad, let compareOp = ti[1].op, var comparison = Self.comparisons[compareOp] else { return nil }
        let load = ti[0].operands, compare = ti[1].operands
        let counter = load[2]
        guard isLocal(counter), test.terminator.operands[0] == compare[1] else { return nil }
        let boundId: SpirvId
        if compare[2] == load[1] {
            boundId = compare[3]
        } else if compare[3] == load[1] {
            boundId = compare[2]
            comparison = Self.swapped[comparison]!
        } else {
            return nil
        }
        guard module.constants[boundId] != nil, let bound = try stage.constantLiteral(boundId) else { return nil }
        let bodyStart: SpirvId
        if test.terminator.operands[2] == merge {
            bodyStart = test.terminator.operands[1]
        } else if test.terminator.operands[1] == merge {
            bodyStart = test.terminator.operands[2]
            comparison = Self.negated[comparison]!
        } else {
            return nil
        }

        // The step: the continue block loads the counter, adds a constant, stores it back.
        let c = try block(cont)
        let ci = Array(c.instructions)
        guard c.merge == nil, c.terminator.op == .opBranch, c.terminator.operands[0] == header.label,
              ci.count == 3, ci[0].op == .opLoad, ci[0].operands[2] == counter,
              ci[2].op == .opStore, ci[2].operands[0] == counter, ci[2].operands[1] == ci[1].operands[1] else { return nil }
        let add = ci[1].operands
        let stepped = ci[0].operands[1]
        var up: Bool
        let stepId: SpirvId
        switch ci[1].op {
        case .opIAdd?, .opFAdd?:
            up = true
            if add[2] == stepped { stepId = add[3] } else if add[3] == stepped { stepId = add[2] } else { return nil }
        case .opISub?, .opFSub?:
            up = false
            guard add[2] == stepped else { return nil }
            stepId = add[3]
        default:
            return nil
        }
        guard module.constants[stepId] != nil, var stepLiteral = try stage.constantLiteral(stepId) else { return nil }
        if stepLiteral.hasPrefix("-") { stepLiteral.removeFirst(); up.toggle() }
        if stepLiteral.hasPrefix("(") { return nil }

        // The start: the constant the counter was just set to.
        guard let start = constantStores[counter] else { return nil }
        guard let pointerType = module.typeOfLocal(counter, in: function),
              case .pointer(_, let counterType) = try module.type(pointerType) else { return nil }
        let isFloat: Bool
        switch counterType {
        case .int(32, true): isFloat = false
        case .float(32): isFloat = true
        default: return nil
        }

        // Nothing in the body may change the counter.
        var seen: Set<SpirvId> = [header.label, merge]
        var queue = [bodyStart]
        while let label = queue.popLast() {
            guard seen.insert(label).inserted, let b = try? block(label) else { continue }
            if label != cont {
                for i in b.body {
                    let o = i.operands
                    switch i.op {
                    case .opStore?, .opCopyMemory?:
                        if o[0] == counter { return nil }
                    case .opFunctionCall?:
                        if o.dropFirst(3).contains(counter) { return nil }
                    case .opAccessChain?, .opInBoundsAccessChain?:
                        if o[2] == counter { return nil }
                    default:
                        break
                    }
                }
            }
            queue += successors(b)
        }
        return CountingLoop(counter: counter, isFloat: isFloat, start: start, comparison: comparison, bound: bound,
                            stepLiteral: stepLiteral, up: up, bodyStart: bodyStart, testBlock: test.label)
    }

    private func successors(_ b: SpirvBlock) -> [SpirvId] {
        let o = b.terminator.operands
        switch b.terminator.op {
        case .opBranch?: return [o[0]]
        case .opBranchConditional?: return [o[1], o[2]]
        case .opSwitch?:
            var out = [o[1]]
            var k = 3
            while k < o.count { out.append(o[k]); k += 2 }
            return out
        default: return []
        }
    }
}

extension SpirvModule {
    /// The pointer type of the `OpVariable` declaring `id` in `function`.
    func typeOfLocal(_ id: SpirvId, in function: SpirvFunction) -> SpirvId? {
        for b in function.blocks {
            for i in b.body where i.op == .opVariable && i.operands[1] == id { return i.operands[0] }
        }
        return nil
    }
}
