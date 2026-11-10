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
//  The start, bound and step may be arithmetic on constants (`RADIUS + 1`),
//  which is folded.
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
    /// Whether code outside the loop reads the counter.
    let readAfter: Bool

    func step(_ index: String) -> String {
        if stepLiteral == "1" { return up ? "\(index)++" : "\(index)--" }
        return "\(index) \(up ? "+=" : "-=") \(stepLiteral)"
    }
}

/// Why a loop is not a counting loop, and where.
struct NotCounting {
    let reason: String
    let at: Located?
}

/// A scalar computed from constants alone.
enum Folded: Hashable {
    case int(Int)
    case float(Float)
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

    // MARK: Folding

    /// `id` as a constant scalar: a module constant, or a value folded from them.
    func foldedValue(_ id: SpirvId, extra: [SpirvId: Folded] = [:]) -> Folded? {
        if let f = extra[id] ?? folded[id] { return f }
        guard let c = module.constants[id], case .scalar(let words) = c.value, let t = module.types[c.type] else { return nil }
        switch t {
        case .int(32, true): return .int(Int(Int32(bitPattern: words[0])))
        case .float(32): return .float(Float(bitPattern: words[0]))
        default: return nil
        }
    }

    /// The value of a scalar int or float instruction on constants, or nil.
    func fold(_ i: Located, extra: [SpirvId: Folded] = [:]) -> Folded? {
        let o = i.operands
        guard let op = i.op, o.count >= 3 else { return nil }
        func v(_ k: Int) -> Folded? { o.count > k ? foldedValue(o[k], extra: extra) : nil }
        switch (op, v(2), v(3)) {
        case (.opIAdd, .int(let a)?, .int(let b)?): return .int(a &+ b)
        case (.opISub, .int(let a)?, .int(let b)?): return .int(a &- b)
        case (.opIMul, .int(let a)?, .int(let b)?): return .int(a &* b)
        case (.opSDiv, .int(let a)?, .int(let b)?) where b != 0: return .int(a / b)
        case (.opSNegate, .int(let a)?, _): return .int(-a)
        case (.opFAdd, .float(let a)?, .float(let b)?): return .float(a + b)
        case (.opFSub, .float(let a)?, .float(let b)?): return .float(a - b)
        case (.opFMul, .float(let a)?, .float(let b)?): return .float(a * b)
        case (.opFDiv, .float(let a)?, .float(let b)?) where b != 0: return .float(a / b)
        case (.opFNegate, .float(let a)?, _): return .float(-a)
        case (.opConvertSToF, .int(let a)?, _): return .float(Float(a))
        case (.opConvertFToS, .float(let a)?, _) where a.isFinite && abs(a) < 2e9: return .int(Int(a))
        case (.opCopyObject, let a?, _): return a
        case (.opLoad, _, _):
            // A local that only holds a parameter folded to a constant.
            if let param = aliasOf(o[2]), let c = folded[param] { return c }
            return nil
        default: return nil
        }
    }

    func literal(_ f: Folded) throws -> String {
        switch f {
        case .int(let k): return k == Int(Int32.min) ? "(-2147483647 - 1)" : "\(k)"
        case .float(let x): return try stage.floatLiteral(x)
        }
    }

    // MARK: Recognizing

    /// The loop at `header` as a counting loop, or why it is not one.
    func countingLoop(_ header: SpirvBlock) throws -> Result<CountingLoop, NotCountingError> {
        let notCounting = { (reason: String, at: Located?) in Result<CountingLoop, NotCountingError>.failure(NotCountingError(NotCounting(reason: reason, at: at))) }
        guard let m = header.merge, m.op == .opLoopMerge else { return notCounting("it has no loop merge", nil) }
        let merge = m.operands[0], cont = m.operands[1]
        guard cont != header.label, !hasPhis(header.label), !hasPhis(merge), !hasPhis(cont) else {
            return notCounting("its values pass between iterations in SSA phis, not in a counter variable", m)
        }

        // The test: the header, or the end of a straight chain of blocks after it.
        var test = header
        while test.terminator.op == .opBranch, test.instructions.allSatisfy({ fold($0) != nil }) {
            let next = test.terminator.operands[0]
            guard next != merge, next != cont, next != header.label, let b = try? block(next), b.merge == nil, !hasPhis(next) else { break }
            test = b
        }
        guard test.terminator.op == .opBranchConditional else {
            return notCounting("it is not a counted loop: it tests no counter against a bound", m)
        }
        // A load of the counter, constants folded, and the comparison the branch takes.
        var extra: [SpirvId: Folded] = [:]
        var load: Located?
        var compare: Located?
        for i in test.instructions {
            if let f = fold(i, extra: extra) { extra[i.operands[1]] = f; continue }
            if i.op == .opLoad, load == nil { load = i; continue }
            if let op = i.op, Self.comparisons[op] != nil, compare == nil { compare = i; continue }
            return notCounting("it is not a counted loop: its test does more than compare a counter with a bound", i)
        }
        guard let load, let compare, test.terminator.operands[0] == compare.operands[1], var comparison = Self.comparisons[compare.op!] else {
            return notCounting("it is not a counted loop: it tests no counter against a bound", m)
        }
        let counter = load.operands[2]
        guard isLocal(counter) else { return notCounting("its counter is not a variable of the function", load) }
        let c2 = compare.operands[2], c3 = compare.operands[3]
        let boundId: SpirvId
        if c2 == load.operands[1] {
            boundId = c3
        } else if c3 == load.operands[1] {
            boundId = c2
            comparison = Self.swapped[comparison]!
        } else {
            return notCounting("it is not a counted loop: it tests no counter against a bound", compare)
        }
        guard let boundValue = foldedValue(boundId, extra: extra) else {
            return notCounting("its bound is computed at run time, where GLSL ES 1.00 needs constant bounds", compare)
        }
        let bound = try literal(boundValue)
        let bodyStart: SpirvId
        if test.terminator.operands[2] == merge {
            bodyStart = test.terminator.operands[1]
        } else if test.terminator.operands[1] == merge {
            bodyStart = test.terminator.operands[2]
            comparison = Self.negated[comparison]!
        } else {
            return notCounting("its test does not leave the loop", compare)
        }

        // The step: the continue block loads the counter, adds a constant, stores it back.
        let c = try block(cont)
        let notStepped = notCounting("it is not a counted loop: no counter steps by a constant at the end of each pass", m)
        guard c.merge == nil, c.terminator.op == .opBranch, c.terminator.operands[0] == header.label else { return notStepped }
        var stepExtra: [SpirvId: Folded] = [:]
        var stepLoad: Located?, stepAdd: Located?, stepStore: Located?
        for i in c.instructions {
            if let f = fold(i, extra: stepExtra) { stepExtra[i.operands[1]] = f; continue }
            switch i.op {
            case .opLoad? where stepLoad == nil && i.operands[2] == counter: stepLoad = i
            case .opIAdd?, .opFAdd?, .opISub?, .opFSub?: if stepAdd == nil { stepAdd = i } else { return notStepped }
            case .opStore? where stepStore == nil && i.operands[0] == counter: stepStore = i
            default: return notStepped
            }
        }
        guard let stepLoad, let stepAdd, let stepStore, stepStore.operands[1] == stepAdd.operands[1] else { return notStepped }
        let add = stepAdd.operands
        let stepped = stepLoad.operands[1]
        var up: Bool
        let stepId: SpirvId
        switch stepAdd.op {
        case .opIAdd?, .opFAdd?:
            up = true
            if add[2] == stepped { stepId = add[3] } else if add[3] == stepped { stepId = add[2] } else { return notStepped }
        default:
            up = false
            guard add[2] == stepped else { return notStepped }
            stepId = add[3]
        }
        guard let stepValue = foldedValue(stepId, extra: stepExtra) else {
            return notCounting("its counter steps by an amount computed at run time", stepAdd)
        }
        var stepLiteral = try literal(stepValue)
        if stepLiteral.hasPrefix("-") { stepLiteral.removeFirst(); up.toggle() }
        if stepLiteral.hasPrefix("(") { return notStepped }

        // The start: the constant the counter was just set to.
        guard let start = constantStores[counter] else {
            return notCounting("its counter does not start at a constant", m)
        }
        guard let pointerType = module.typeOfLocal(counter, in: function),
              case .pointer(_, let counterType) = try module.type(pointerType) else { return notStepped }
        let isFloat: Bool
        switch counterType {
        case .int(32, true): isFloat = false
        case .float(32): isFloat = true
        default: return notCounting("its counter is neither an int nor a float", load)
        }

        // Nothing in the body may change the counter.
        var seen: Set<SpirvId> = [header.label, merge]
        var queue = [bodyStart]
        while let label = queue.popLast() {
            guard seen.insert(label).inserted, let b = try? block(label) else { continue }
            if label != cont {
                for i in b.body {
                    let o = i.operands
                    let changes: Bool
                    switch i.op {
                    case .opStore?, .opCopyMemory?: changes = o[0] == counter
                    case .opFunctionCall?: changes = o.dropFirst(3).contains(counter)
                    case .opAccessChain?, .opInBoundsAccessChain?: changes = o[2] == counter
                    default: changes = false
                    }
                    if changes { return notCounting("its counter changes inside the loop", i) }
                }
            }
            queue += successors(b)
        }
        // Whether anything outside the loop reads the counter; the loop is the blocks seen from the body, its header chain and continue block.
        var inLoop = seen
        inLoop.remove(merge)
        var chain = header.label
        while chain != test.label, let b = try? block(chain), b.terminator.op == .opBranch {
            inLoop.insert(chain)
            chain = b.terminator.operands[0]
        }
        inLoop.insert(test.label)
        inLoop.insert(cont)
        let readAfter = function.blocks.contains { b in
            !inLoop.contains(b.label) && b.body.contains { i in
                (i.op == .opLoad && i.operands[2] == counter)
                    || ((i.op == .opAccessChain || i.op == .opInBoundsAccessChain) && i.operands[2] == counter)
                    || (i.op == .opFunctionCall && i.operands.dropFirst(3).contains(counter))
                    || (i.op == .opCopyMemory && i.operands[1] == counter)
            }
        }
        return .success(CountingLoop(counter: counter, isFloat: isFloat, start: start, comparison: comparison, bound: bound,
                                     stepLiteral: stepLiteral, up: up, bodyStart: bodyStart, testBlock: test.label, readAfter: readAfter))
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

/// `NotCounting` as an Error, for `Result`.
struct NotCountingError: Error {
    let value: NotCounting
    init(_ value: NotCounting) { self.value = value }
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
