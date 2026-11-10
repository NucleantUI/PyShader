//
//  CountedParameters.swift
//  Spirv2GLSL
//
//  A function whose loop counts to one of its parameters (`for i in
//  range(octaves)`) has no Appendix A form of its own: the bound is a value
//  at run time. Called with a constant there, it does: the function is
//  written once per set of constants it is called with (`fbm_5`), the
//  parameter folded into its loops. Which parameters a function counts with
//  — a loop's start, bound or step, or one passed on to a function that
//  counts with it — is found here, before any function is written.
//

import SpirvCore

extension StageWriter {
    /// The parameters (by position) each function's loops count with.
    func countedParameters() -> [SpirvId: Set<Int>] {
        var counted: [SpirvId: Set<Int>] = [:]
        // Each function's locals that only hold one of its parameters: its index.
        var copies: [SpirvId: [SpirvId: Int]] = [:]
        for id in functionOrder {
            copies[id] = parameterCopies(of: module.functions[id]!)
        }
        func parameter(_ value: SpirvId, in f: SpirvFunction, loads: [SpirvId: SpirvId]) -> Int? {
            if let k = f.params.firstIndex(where: { $0.id == value }) { return k }
            if let variable = loads[value] { return copies[f.id]?[variable] }
            return nil
        }
        var changed = true
        while changed {
            changed = false
            for id in functionOrder {
                let f = module.functions[id]!
                var loads: [SpirvId: SpirvId] = [:]   // load result -> variable
                for b in f.blocks { for i in b.body where i.op == .opLoad { loads[i.operands[1]] = i.operands[2] } }
                var found = counted[id] ?? []
                for b in f.blocks {
                    for i in b.body {
                        switch i.op {
                        case .opLoopMerge?:
                            // The values the loop's test compares, and what its counter steps by and starts at.
                            for v in loopValues(b, in: f) {
                                if let k = parameter(v, in: f, loads: loads) { found.insert(k) }
                            }
                        case .opFunctionCall?:
                            for k in counted[i.operands[2]] ?? [] where 3 + k < i.operands.count {
                                if let j = parameter(i.operands[3 + k], in: f, loads: loads) { found.insert(j) }
                            }
                        default:
                            break
                        }
                    }
                }
                if found != counted[id] ?? [] {
                    counted[id] = found
                    changed = true
                }
            }
        }
        return counted.filter { !$0.value.isEmpty }
    }

    /// The ids a loop's counting rests on: the operands its test compares,
    /// the step its continue block adds, the values stored to its counter.
    private func loopValues(_ header: SpirvBlock, in f: SpirvFunction) -> [SpirvId] {
        guard let m = header.merge, m.op == .opLoopMerge else { return [] }
        let blocks = Dictionary(uniqueKeysWithValues: f.blocks.map { ($0.label, $0) })
        var out: [SpirvId] = []
        var test = header
        var seen: Set<SpirvId> = []
        while test.terminator.op == .opBranch, seen.insert(test.label).inserted, let next = blocks[test.terminator.operands[0]] {
            test = next
        }
        var counters: Set<SpirvId> = []
        for i in test.instructions {
            if let op = i.op, Self.isComparison(op) { out += [i.operands[2], i.operands[3]] }
            if i.op == .opLoad { counters.insert(i.operands[2]) }
        }
        if let c = blocks[m.operands[1]] {
            for i in c.instructions where i.op == .opIAdd || i.op == .opISub || i.op == .opFAdd || i.op == .opFSub {
                out += [i.operands[2], i.operands[3]]
            }
        }
        for b in f.blocks {
            for i in b.body where i.op == .opStore && counters.contains(i.operands[0]) { out.append(i.operands[1]) }
        }
        return out
    }

    private static func isComparison(_ op: SpirvOp) -> Bool {
        switch op {
        case .opSLessThan, .opSLessThanEqual, .opSGreaterThan, .opSGreaterThanEqual, .opIEqual, .opINotEqual,
             .opFOrdLessThan, .opFOrdLessThanEqual, .opFOrdGreaterThan, .opFOrdGreaterThanEqual,
             .opFUnordLessThan, .opFUnordLessThanEqual, .opFUnordGreaterThan, .opFUnordGreaterThanEqual:
            return true
        default:
            return false
        }
    }

    /// `f`'s locals that the entry block sets from a parameter (by position)
    /// and nothing writes again.
    func parameterCopies(of f: SpirvFunction) -> [SpirvId: Int] {
        guard let first = f.blocks.first else { return [:] }
        var chainRoot: [SpirvId: SpirvId] = [:]
        var writes: [SpirvId: Int] = [:]
        for b in f.blocks {
            for i in b.body {
                let o = i.operands
                switch i.op {
                case .opAccessChain?, .opInBoundsAccessChain?: chainRoot[o[1]] = chainRoot[o[2]] ?? o[2]
                case .opStore?, .opCopyMemory?: writes[chainRoot[o[0]] ?? o[0], default: 0] += 1
                case .opFunctionCall?: for a in o.dropFirst(3) { writes[chainRoot[a] ?? a, default: 0] += 1 }
                default: break
                }
            }
        }
        var out: [SpirvId: Int] = [:]
        for i in first.body where i.op == .opStore {
            if let k = f.params.firstIndex(where: { $0.id == i.operands[1] }), writes[i.operands[0]] == 1 {
                out[i.operands[0]] = k
            }
        }
        return out
    }
}
