//
//  FunctionDecompiler.swift
//  Spirv2PyShader
//
//  Writes one SPIR-V function as a Python `def`. SSA values become
//  expression trees that are inlined at their single use (or where they are
//  cheap to re-read) and otherwise land in `_tN` temporaries; `OpVariable`s
//  are Python locals, loads read them and stores assign them. Structured
//  control flow is walked from the entry block: a selection merge is an
//  `if`, a loop merge a `while` whose continue block is kept aside, and a
//  branch to a loop's merge or continue label is `break` / `continue`.
//
//  Inlining an expression past a later store to a variable it reads would
//  change its value, so every store first materialises the pending
//  expressions that read the stored variable, at the nesting depth they were
//  defined at (which places the temporary before the `if`/`while` the store
//  sits in).
//

import PyShader
import SpirvCore

struct PyFunction {
    let name: String
    let params: [(name: String, type: String)]
    let returnType: String?
    var body: [PyStmt]
    let isEntry: Bool
    let localTypes: [String: ShaderType]

    var rendered: String {
        let sig = params.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
        let ret = returnType.map { " -> \($0)" } ?? ""
        return "def \(name)(\(sig))\(ret):\n" + PyStmt.render(body)
    }
}

/// An SSA value as an expression, with what it reads so a store can tell whether it must be pinned first.
private struct ValueEntry {
    var expr: PyExpr
    let type: ShaderType
    var reads: Set<String>
    /// Index into the statement stack where the value was defined.
    let depth: Int
    /// Already a temporary or a parameter: never needs pinning.
    var pinned: Bool
    var remaining: Int
}

/// A pointer as a Python place: `p`, `p.x`, `colors[i].rgb`.
struct Place {
    var expr: PyExpr
    var type: ShaderType
    /// The Python variable the place is rooted in.
    var root: String
    var reads: Set<String>
}

final class FunctionDecompiler {
    let ctx: ModuleDecompiler
    var module: ModuleIndex { ctx.module }
    var analysis: ModuleAnalysis { ctx.analysis }
    let fn: FunctionDef
    let scan: FunctionScan
    let isEntry: Bool

    private var names: NameAllocator
    /// Pointer roots (variables, pointer parameters) -> Python name.
    private var rootNames: [SpirvId: String] = [:]
    private var places: [SpirvId: Place] = [:]
    private(set) var localTypes: [String: ShaderType] = [:]
    private var values: [SpirvId: ValueEntry] = [:]
    /// Ids in definition order, for pinning in order.
    private var valueOrder: [SpirvId] = []
    private var phiNames: [SpirvId: String] = [:]
    /// `OpCompositeExtract`s folded into the `OpCompositeConstruct` that rebuilds their source.
    private var absorbedExtracts: [SpirvId: SpirvId] = [:]
    /// Stores of parameters into the locals PyShader copies them to; the local takes the parameter's name.
    private var skippedStores: Set<Int> = []
    /// Shuffles that may become swizzle stores: (vector loaded, value written, indices).
    private var shuffles: [SpirvId: (source: SpirvId, sourceExpr: PyExpr, value: PyExpr, indices: [Int])] = [:]
    /// Tuple values unpacked into one temporary per member.
    private var unpacked: [SpirvId: [String]] = [:]

    /// Use counts after folding absorbed extracts into their source.
    private var useCountAdjust: [SpirvId: Int] = [:]

    private var stack: [[PyStmt]] = [[]]
    private var loops: [(header: SpirvId, merge: SpirvId, cont: SpirvId)] = []
    private var tempCounter = 0
    private var paramNames: [(name: String, type: String)] = []
    private var outParamNames: [String] = []

    init(ctx: ModuleDecompiler, function: FunctionDef) {
        self.ctx = ctx
        self.fn = function
        self.scan = ctx.analysis.scan(function.id)
        self.isEntry = function.id == ctx.analysis.entry.id
        // Interface values this function takes keep their names; the entry point's output too.
        var reserved = Set((ctx.analysis.threaded[function.id] ?? []).map(\.name))
        if isEntry { reserved.insert(ctx.analysis.interface.outputName) }
        reserved.formUnion(ctx.analysis.functionNames.values)
        reserved.formUnion(ctx.analysis.structNames.values)
        names = NameAllocator(reserved: reserved)
    }

    // MARK: - Driving

    func decompile() throws -> PyFunction {
        prepareConstructs()
        try declareParameters()
        if isEntry, let out = analysis.interface.output {
            localTypes[analysis.interface.outputName] = module.globals[out]!.type
        }
        for v in analysis.threaded[fn.id] ?? [] where !isEntry {
            paramNames.append((v.name, analysis.typeName(v.type)))
        }
        if isEntry {
            for v in (analysis.threaded[fn.id] ?? []) {
                paramNames.append((v.name, analysis.typeName(v.type)))
            }
        }
        guard let first = fn.blocks.first else { throw error("function has no body") }
        guard case .done = try emitRegion(from: first.label, until: nil) else { throw error("the body leaves through an unknown label") }

        let returnTypes = analysis.returnTypes(fn.id)
        let returnType: String?
        if isEntry {
            returnType = analysis.interface.output.map { analysis.typeName(module.globals[$0]!.type) }
        } else if returnTypes.isEmpty {
            returnType = nil
        } else if returnTypes.count == 1 {
            returnType = analysis.typeName(returnTypes[0])
        } else {
            returnType = "tuple[\(returnTypes.map(analysis.typeName).joined(separator: ", "))]"
        }
        return PyFunction(name: analysis.name(of: fn.id), params: paramNames, returnType: returnType, body: stack[0], isEntry: isEntry, localTypes: localTypes)
    }

    private func declareParameters() throws {
        let outs = Set(analysis.outParams[fn.id] ?? [])
        for (i, p) in fn.params.enumerated() {
            let raw = module.names[p.id]
            if let pointee = p.type.pointee {
                // glslang passes everything by pointer: the parameter is a local.
                let name = names.unique(raw ?? "p\(i)", fallback: "p")
                rootNames[p.id] = name
                localTypes[name] = pointee
                paramNames.append((name, analysis.typeName(pointee)))
                if outs.contains(i) { outParamNames.append(name) }
            } else {
                // PyShader copies each parameter into a local of the same name on entry.
                var name: String?
                if let users = scan.users[p.id], users.count == 1, let store = users.first, store.op == .opStore,
                   store.operands[1] == p.id, let varInst = scan.defs[store.operands[0]], varInst.op == .opVariable,
                   fn.blocks[0].instructions.contains(where: { $0.offset == store.offset }),
                   let varName = module.names[varInst.operands[1]] {
                    name = names.unique(varName, fallback: "p")
                    rootNames[varInst.operands[1]] = name
                    localTypes[name!] = p.type
                    skippedStores.insert(store.offset)
                }
                let final = name ?? names.unique(raw ?? "p\(i)", fallback: "p")
                values[p.id] = ValueEntry(expr: .name(final), type: p.type, reads: [final], depth: 0, pinned: true, remaining: .max)
                paramNames.append((final, analysis.typeName(p.type)))
            }
        }
    }

    /// Marks runs of `OpCompositeExtract`s that an `OpCompositeConstruct` puts
    /// straight back together, so the source vector is used once, as itself.
    private func prepareConstructs() {
        for inst in fn.allInstructions where inst.op == .opCompositeConstruct {
            guard case .vector(_, let n)? = module.types[inst.operands[0]] else { continue }
            let ids = Array(inst.operands.dropFirst(2))
            var i = 0
            while i < ids.count {
                guard let (source, index) = singleExtract(ids[i]), index == 0,
                      case .vector(_, let sourceCount)? = scan.resultTypes[source] else { i += 1; continue }
                var count = 1
                while i + count < ids.count, let (s, k) = singleExtract(ids[i + count]), s == source, k == count { count += 1 }
                let whole = count == sourceCount
                let truncation = count == ids.count && count == n
                if count > 1, whole || truncation {
                    for k in 0..<count { absorbedExtracts[ids[i + k]] = source }
                    useCountAdjust[source, default: 0] -= count - 1
                }
                i += count
            }
        }
    }

    private func singleExtract(_ id: SpirvId) -> (SpirvId, Int)? {
        guard let d = scan.defs[id], d.op == .opCompositeExtract, d.operands.count == 4, scan.useCounts[id] == 1 else { return nil }
        return (d.operands[2], Int(d.operands[3]))
    }

    private func useCount(_ id: SpirvId) -> Int {
        (scan.useCounts[id] ?? 0) + (useCountAdjust[id] ?? 0)
    }

    // MARK: - Errors & warnings

    func error(_ message: String) -> Spirv2PyShaderError {
        Spirv2PyShaderError("\(analysis.name(of: fn.id)): \(message)")
    }

    func warn(_ message: String) {
        ctx.warn("\(analysis.name(of: fn.id)): \(message)")
    }

    // MARK: - Statements

    private func emit(_ s: PyStmt) {
        stack[stack.count - 1].append(s)
    }

    func emitStatement(_ s: PyStmt) { emit(s) }

    func temporary() -> String { temp() }

    private func temp() -> String {
        tempCounter += 1
        return names.unique("_t\(tempCounter)", fallback: "_t")
    }

    // MARK: - Values

    /// Defines the result of an instruction.
    func define(_ id: SpirvId, _ expr: PyExpr, type: ShaderType, reads: Set<String>) {
        let uses = useCount(id)
        if uses == 0 {
            if hasUserCall(expr) { emit(.expr(expr)) }
            return
        }
        if uses == 1 || isTrivial(expr) {
            values[id] = ValueEntry(expr: expr, type: type, reads: reads, depth: stack.count - 1, pinned: false, remaining: uses)
            valueOrder.append(id)
            return
        }
        // Multi-use: a temporary, or one per member for a tuple that is only taken apart.
        if case .tuple(let members) = type,
           let users = scan.users[id], users.allSatisfy({ $0.op == .opCompositeExtract && $0.operands.count == 4 }) {
            let base = temp()
            let parts = members.indices.map { names.unique("\(base)_\($0)", fallback: "_t") }
            emit(.assign(.tuple(parts.map { .name($0) }), expr))
            unpacked[id] = parts
            values[id] = ValueEntry(expr: .name(base), type: type, reads: [], depth: stack.count - 1, pinned: true, remaining: uses)
            return
        }
        let name = temp()
        localTypes[name] = type
        emit(.assign(.name(name), expr))
        values[id] = ValueEntry(expr: .name(name), type: type, reads: [name], depth: stack.count - 1, pinned: true, remaining: uses)
    }

    private func hasUserCall(_ e: PyExpr) -> Bool {
        if case .call(let f, _) = e, ctx.userFunctionNames.contains(f) { return true }
        return e.children.contains { hasUserCall($0) }
    }

    private func isTrivial(_ e: PyExpr) -> Bool {
        switch e {
        case .name, .number, .bool: return true
        case .attr(let b, _): return isTrivial(b)
        case .index(let b, let i): return isTrivial(b) && isTrivial(i)
        case .call(let f, let args) where ShaderType.named(f) != nil && args.count == 1: return isTrivial(args[0])
        case .list(let elts), .tuple(let elts): return elts.allSatisfy(isTrivial)
        default: return false
        }
    }

    /// The expression for an operand.
    func use(_ id: SpirvId) throws -> PyExpr {
        if let c = module.constants[id] { return try ctx.render(constant: c) }
        if var v = values[id] {
            if v.remaining != .max {
                v.remaining -= 1
                if v.remaining == 0 { values[id] = nil } else { values[id] = v }
            }
            return v.expr
        }
        if let name = phiNames[id] { return .name(name) }
        if module.function(id) != nil { return .name(analysis.name(of: id)) }
        if let place = places[id] { return place.expr }
        throw error("%\(id) is used before it is defined")
    }

    func type(of id: SpirvId) throws -> ShaderType {
        if let c = module.constants[id] { return c.type }
        if let v = values[id] { return v.type }
        if let t = scan.resultTypes[id] { return t }
        if let name = phiNames[id], let t = localTypes[name] { return t }
        throw error("%\(id) has no known type")
    }

    /// Everything an expression for `id` reads (for pinning decisions).
    func reads(_ id: SpirvId) -> Set<String> {
        if let v = values[id] { return v.reads }
        if let name = phiNames[id] { return [name] }
        return []
    }

    /// Before `root` is written: pin every pending expression that reads it.
    private func invalidate(_ root: String) {
        for id in valueOrder {
            guard var v = values[id], !v.pinned, v.reads.contains(root) else { continue }
            let name = temp()
            localTypes[name] = v.type
            stack[v.depth].append(.assign(.name(name), v.expr))
            v.expr = .name(name)
            v.reads = [name]
            v.pinned = true
            values[id] = v
        }
        valueOrder.removeAll { values[$0] == nil || values[$0]!.pinned }
    }

    // MARK: - Places

    func place(_ pointer: SpirvId) throws -> Place {
        if let p = places[pointer] { return p }
        if let name = rootNames[pointer] {
            return Place(expr: .name(name), type: localTypes[name]!, root: name, reads: [name])
        }
        if let g = module.globals[pointer] {
            return try place(global: g)
        }
        throw error("%\(pointer) is not a variable")
    }

    private func place(global g: GlobalVariable) throws -> Place {
        let map = analysis.interface
        if let v = map.variables[g.id] {
            return Place(expr: .name(v.name), type: v.type, root: v.name, reads: [v.name])
        }
        if g.id == map.output {
            let name = map.outputName
            localTypes[name] = g.type
            return Place(expr: .name(name), type: g.type, root: name, reads: [name])
        }
        if map.members[g.id] != nil {
            // Resolved by the first access-chain index.
            return Place(expr: .name("<block>"), type: g.type, root: "<block \(g.id)>", reads: [])
        }
        if let name = map.opaque[g.id] {
            throw error("`\(name)` is a sampler or image; PyShader's fragment target has no textures")
        }
        if let name = map.privateGlobals[g.id] {
            throw error("`\(name)` is a module-level variable; PyShader has only constants outside functions")
        }
        throw error("global `\(g.name ?? "%\(g.id)")` (\(g.storage)) is not supported")
    }

    private func accessChain(_ inst: Instruction) throws {
        let id = inst.operands[1]
        var p = try place(inst.operands[2])
        for (k, indexId) in inst.operands.dropFirst(3).enumerated() {
            let constant: Int? = {
                if let c = module.constants[indexId], case .int(let v) = c.value { return Int(v) }
                return nil
            }()
            if k == 0, p.root.hasPrefix("<block "), let blockId = SpirvId(p.root.dropFirst(7).dropLast()) {
                guard let c = constant, let v = analysis.interface.members[blockId]?[c] else {
                    throw error("member \(constant.map(String.init) ?? "?") of block `\(module.globals[blockId]?.name ?? "")` is not an interface value")
                }
                p = Place(expr: .name(v.name), type: v.type, root: v.name, reads: [v.name])
                continue
            }
            switch p.type {
            case .vector(let kind, _):
                if let c = constant {
                    p.expr = .attr(p.expr, component(c))
                } else {
                    let i = try use(indexId)
                    p.reads.formUnion(reads(indexId))
                    p.expr = .index(p.expr, i)
                }
                p.type = .scalar(kind)
            case .matrix(let kind, _, let rows):
                let i = try index(indexId, constant)
                p.expr = .index(p.expr, i)
                p.reads.formUnion(reads(indexId))
                p.type = .vector(kind, rows)
            case .array(let elem, _), .runtimeArray(let elem):
                let i = try index(indexId, constant)
                p.expr = .index(p.expr, i)
                p.reads.formUnion(reads(indexId))
                p.type = elem
            case .structure(let name, let members):
                guard let c = constant, members.indices.contains(c) else { throw error("non-constant member index into `\(name)`") }
                p.expr = .attr(p.expr, members[c].0)
                p.type = members[c].1
            case .tuple(let members):
                guard let c = constant, members.indices.contains(c) else { throw error("non-constant index into a tuple") }
                p.expr = .index(p.expr, .number("\(c)"))
                p.type = members[c]
            default:
                throw error("cannot index into a `\(p.type)`")
            }
        }
        places[id] = p
    }

    private func index(_ id: SpirvId, _ constant: Int?) throws -> PyExpr {
        if let c = constant { return .number("\(c)") }
        return try use(id)
    }

    // MARK: - Regions

    /// Where control went after a block or region.
    private enum Flow {
        /// Continue with this block.
        case next(SpirvId)
        /// Reached the region's stop label, or left through return / break / continue.
        case done
        /// Jumped to the merge of an enclosing construct (spirv-opt's `switch` breaks for early returns).
        case escaped(SpirvId)
    }

    /// Stop labels of the regions being emitted, innermost last.
    private var regionStops: [SpirvId] = []

    /// Emits blocks from `start` until control reaches `stop` (a merge or continue label).
    @discardableResult
    private func emitRegion(from start: SpirvId, until stop: SpirvId?) throws -> Flow {
        if let stop { regionStops.append(stop) }
        defer { if stop != nil { regionStops.removeLast() } }
        var current = start
        while current != stop {
            guard let block = fn.block(current) else { throw error("branch to unknown block %\(current)") }
            switch try emitBlock(block, stop: stop) {
            case .next(let label): current = label
            case .done: return .done
            case .escaped(let label): return .escaped(label)
            }
        }
        return .done
    }

    /// Emits one block and its structured successors.
    private func emitBlock(_ block: Block, stop: SpirvId?) throws -> Flow {
        // Phis take their value from copies at the end of each predecessor; here they are just names.
        for phi in block.phis {
            let name = phiName(phi.operands[1])
            if let t = module.types[phi.operands[0]] { localTypes[name] = t }
        }
        if let merge = block.merge, merge.op == .opLoopMerge {
            return try emitLoop(block, merge: merge, stop: stop)
        }
        for inst in block.body where inst.op != .opPhi {
            try emitInstruction(inst)
        }
        return try emitTerminator(block, stop: stop)
    }

    private func emitTerminator(_ block: Block, stop: SpirvId?) throws -> Flow {
        let term = block.terminator
        switch term.op {
        case .opBranch:
            let target = term.operands[0]
            try phiCopies(from: block.label, to: target)
            return try jump(to: target, stop: stop)

        case .opBranchConditional:
            let cond = try use(term.operands[0])
            let t = term.operands[1], f = term.operands[2]
            try phiCopies(from: block.label, to: t)
            if f != t { try phiCopies(from: block.label, to: f) }
            if let merge = block.merge, merge.op == .opSelectionMerge {
                return try emitSelection(cond, t, f, merge: merge.operands[0], stop: stop)
            }
            // A loop condition (no selection merge): one side leaves the loop or the region.
            let tKind = classify(t, stop: stop), fKind = classify(f, stop: stop)
            switch (tKind, fKind) {
            case (.other, .other):
                throw error("conditional branch without a selection merge at %\(block.label)")
            case (.other, _):
                emitIf(.not(cond), try nested { try self.jumpStatements(f, stop: stop) }, [])
                return .next(t)
            case (_, .other):
                emitIf(cond, try nested { try self.jumpStatements(t, stop: stop) }, [])
                return .next(f)
            default:
                emitIf(cond, try nested { try self.jumpStatements(t, stop: stop) }, try nested { try self.jumpStatements(f, stop: stop) })
                return .done
            }

        case .opReturn:
            emit(.ret(returnValue(nil)))
            return .done
        case .opReturnValue:
            emit(.ret(returnValue(try use(term.operands[0]))))
            return .done
        case .opKill:
            emit(.expr(.call("discard", [])))
            return .done
        case .opUnreachable:
            return .done
        case .opSwitch:
            guard let merge = block.merge, merge.op == .opSelectionMerge else {
                throw error("`switch` without a selection merge at %\(block.label)")
            }
            return try emitSwitch(term, merge: merge.operands[0], from: block.label, stop: stop)
        default:
            throw error("unexpected block terminator \(term.op.map { "\($0)" } ?? "opcode \(term.opcode)")")
        }
    }

    /// `if cond:` with the two arms; an arm that jumps out to the enclosing
    /// construct's end takes the rest of the region into the other arm.
    private func emitSelection(_ cond: PyExpr, _ t: SpirvId, _ f: SpirvId, merge m: SpirvId, stop: SpirvId?) throws -> Flow {
        let (thenStmts, thenFlow) = try nested { try self.branchArm(t, merge: m, stop: stop) }
        let (elseStmts, elseFlow) = try nested { try self.branchArm(f, merge: m, stop: stop) }
        switch (thenFlow, elseFlow) {
        case (.done, .done):
            emitIf(cond, thenStmts, elseStmts)
            return m == stop ? .done : .next(m)
        case (.escaped(let x), .escaped(let y)):
            guard x == y else { throw error("branches leaving to different constructs at %\(m)") }
            emitIf(cond, thenStmts, elseStmts)
            return .escaped(x)
        case (.escaped(let x), .done):
            let (rest, flow) = try nested { () throws -> Flow in m == stop ? .done : try self.emitRegion(from: m, until: stop) }
            emitIf(cond, thenStmts, elseStmts + rest)
            return try afterEscape(x, flow, stop: stop)
        case (.done, .escaped(let x)):
            let (rest, flow) = try nested { () throws -> Flow in m == stop ? .done : try self.emitRegion(from: m, until: stop) }
            emitIf(cond, thenStmts + rest, elseStmts)
            return try afterEscape(x, flow, stop: stop)
        default:
            preconditionFailure("arms never return .next")
        }
    }

    private func afterEscape(_ target: SpirvId, _ restFlow: Flow, stop: SpirvId?) throws -> Flow {
        if case .done = restFlow, target == stop { return .done }
        throw error("an early exit crosses more than one construct; decompile unoptimised SPIR-V")
    }

    /// `switch` as an `if`/`elif` chain on the selector; a case falling
    /// through into the next one repeats that case's statements.
    private func emitSwitch(_ term: Instruction, merge: SpirvId, from label: SpirvId, stop: SpirvId?) throws -> Flow {
        var selector = try use(term.operands[0])
        let defaultLabel = term.operands[1]
        var cases: [(labels: [PyExpr], target: SpirvId)] = []
        var i = 2
        while i + 1 < term.operands.count {
            let literal = PyExpr.number("\(Int32(bitPattern: term.operands[i]))")
            let target = term.operands[i + 1]
            if let k = cases.firstIndex(where: { $0.target == target }) {
                cases[k].labels.append(literal)
            } else {
                cases.append(([literal], target))
            }
            i += 2
        }
        if !isTrivial(selector) {
            let name = temp()
            emit(.assign(.name(name), selector))
            selector = .name(name)
        }
        try phiCopies(from: label, to: defaultLabel)
        for c in cases { try phiCopies(from: label, to: c.target) }

        var chain = try nested { try self.branchArm(defaultLabel, merge: merge, stop: stop) }
        guard case .done = chain.flow else { throw error("a switch case leaves the construct") }
        for c in cases.reversed() {
            let cond = c.labels.map { PyExpr.compare("==", selector, $0) }.reduce(nil as PyExpr?) { acc, e in acc.map { .boolOp("or", $0, e) } ?? e }!
            let arm = try nested { try self.branchArm(c.target, merge: merge, stop: stop) }
            guard case .done = arm.flow else { throw error("a switch case leaves the construct") }
            if arm.stmts.isEmpty, chain.stmts.isEmpty { continue }
            chain.stmts = [.ifStmt(cond, arm.stmts, chain.stmts)]
        }
        for s in chain.stmts { emit(s) }
        return merge == stop ? .done : .next(merge)
    }

    private enum JumpKind { case stop, breakLoop, continueLoop, escape, other }

    private func classify(_ target: SpirvId, stop: SpirvId?) -> JumpKind {
        if target == stop { return .stop }
        if let loop = loops.last {
            if target == loop.merge { return .breakLoop }
            if target == loop.cont { return .continueLoop }
        }
        if regionStops.contains(target) { return .escape }
        return .other
    }

    /// Follows an unconditional branch: the next block of the region, or a `break` / `continue`.
    private func jump(to target: SpirvId, stop: SpirvId?) throws -> Flow {
        switch classify(target, stop: stop) {
        case .stop: return .done
        case .breakLoop: emit(.breakStmt); return .done
        case .continueLoop: emit(.continueStmt); return .done
        case .escape: return .escaped(target)
        case .other: return .next(target)
        }
    }

    /// The statements a jump to `target` stands for, inside a nested arm.
    private func jumpStatements(_ target: SpirvId, stop: SpirvId?) throws {
        switch try jump(to: target, stop: stop) {
        case .next(let label):
            guard case .done = try emitRegion(from: label, until: stop) else {
                throw error("an early exit crosses a loop condition; decompile unoptimised SPIR-V")
            }
        case .done: break
        case .escaped: throw error("an early exit crosses a loop condition; decompile unoptimised SPIR-V")
        }
    }

    private func branchArm(_ target: SpirvId, merge: SpirvId, stop: SpirvId?) throws -> Flow {
        if target == merge { return .done }
        switch classify(target, stop: stop) {
        case .breakLoop: emit(.breakStmt); return .done
        case .continueLoop: emit(.continueStmt); return .done
        case .stop: return .done
        case .escape: return .escaped(target)
        case .other: return try emitRegion(from: target, until: merge)
        }
    }

    private func emitIf(_ cond: PyExpr, _ thenStmts: [PyStmt], _ elseStmts: [PyStmt]) {
        if thenStmts.isEmpty, elseStmts.isEmpty { return }
        if thenStmts.isEmpty {
            emit(.ifStmt(.not(cond), elseStmts, []))
        } else {
            emit(.ifStmt(cond, thenStmts, elseStmts))
        }
    }

    private func nested(_ body: () throws -> Void) throws -> [PyStmt] {
        stack.append([])
        try body()
        return stack.removeLast()
    }

    private func nested(_ body: () throws -> Flow) throws -> (stmts: [PyStmt], flow: Flow) {
        stack.append([])
        let flow = try body()
        return (stack.removeLast(), flow)
    }

    /// A loop header: its own instructions run each iteration first, then the
    /// region up to the continue label is the body, the continue block the `next` part.
    private func emitLoop(_ header: Block, merge: Instruction, stop: SpirvId?) throws -> Flow {
        let mergeLabel = merge.operands[0], contLabel = merge.operands[1]
        loops.append((header.label, mergeLabel, contLabel))
        defer { loops.removeLast() }

        let body = try nested { () throws -> Flow in
            for inst in header.body where inst.op != .opPhi {
                try emitInstruction(inst)
            }
            self.regionStops.append(contLabel)
            defer { self.regionStops.removeLast() }
            switch try self.emitTerminator(header, stop: contLabel) {
            case .next(let label): return try self.emitRegion(from: label, until: contLabel)
            case let flow: return flow
            }
        }
        guard case .done = body.flow else { throw error("a loop body leaves an enclosing construct; decompile unoptimised SPIR-V") }
        let next = try nested { () throws -> Flow in
            contLabel == header.label ? .done : try self.emitRegion(from: contLabel, until: header.label)
        }
        guard case .done = next.flow else { throw error("a loop's continue block leaves an enclosing construct") }
        emit(.loop(cond: nil, body: body.stmts, next: next.stmts))
        return mergeLabel == stop ? .done : .next(mergeLabel)
    }

    // MARK: - Phis

    private func phiName(_ id: SpirvId) -> String {
        if let n = phiNames[id] { return n }
        let n = names.unique("_p\(id)", fallback: "_p")
        phiNames[id] = n
        return n
    }

    /// Copies for the phis of `target` that take their value from `from`.
    private func phiCopies(from: SpirvId, to target: SpirvId) throws {
        guard let block = fn.block(target) else { return }
        for phi in block.phis {
            let pairs = stride(from: 2, to: phi.operands.count, by: 2).map { (phi.operands[$0], phi.operands[$0 + 1]) }
            guard let (valueId, _) = pairs.first(where: { $0.1 == from }) else { continue }
            let name = phiName(phi.operands[1])
            let value = try use(valueId)
            invalidate(name)
            emit(.assign(.name(name), value))
        }
    }

    // MARK: - Returns

    private func returnValue(_ value: PyExpr?) -> PyExpr? {
        if isEntry {
            return analysis.interface.output.map { _ in .name(analysis.interface.outputName) }
        }
        var parts: [PyExpr] = value.map { [$0] } ?? []
        parts += outParamNames.map { .name($0) }
        if parts.isEmpty { return nil }
        return parts.count == 1 ? parts[0] : .tuple(parts)
    }

    // MARK: - Instructions

    private func emitInstruction(_ inst: Instruction) throws {
        guard let op = inst.op else {
            throw error("opcode \(inst.opcode) at word \(inst.offset) is not supported")
        }
        switch op {
        case .opVariable:
            let id = inst.operands[1]
            if rootNames[id] == nil {
                // Unnamed variables are compiler temporaries (glslang's `?:` results).
                let name = names.unique(module.names[id] ?? "_v\(id)", fallback: "_v")
                rootNames[id] = name
            }
            localTypes[rootNames[id]!] = module.types[inst.operands[0]]?.pointee ?? .void
            if inst.operands.count > 3 {
                emit(.assign(.name(rootNames[id]!), try use(inst.operands[3])))
            }

        case .opAccessChain, .opInBoundsAccessChain:
            try accessChain(inst)

        case .opLoad:
            let p = try place(inst.operands[2])
            if p.root.hasPrefix("<block") { throw error("loading a whole uniform block is not supported") }
            define(inst.operands[1], p.expr, type: p.type, reads: p.reads)

        case .opStore:
            if skippedStores.contains(inst.offset) { return }
            try store(inst)

        case .opFunctionCall:
            try call(inst)

        case .opCopyObject:
            define(inst.operands[1], try use(inst.operands[2]), type: try type(of: inst.operands[2]), reads: reads(inst.operands[2]))

        case .opSelectionMerge, .opLoopMerge, .opLabel, .opNop, .opUndef:
            break

        default:
            guard hasResult(op) else { throw error("\(op) is not supported") }
            let id = inst.operands[1]
            guard let t = module.types[inst.operands[0]] else { throw error("%\(id) has a type PyShader cannot express") }
            if absorbedExtracts[id] != nil { return }
            let operands = valueOperands(inst)
            var reads = Set<String>()
            for o in operands { reads.formUnion(self.reads(o)) }
            let expr = try expression(inst, op, type: t)
            define(id, expr, type: t, reads: reads)
        }
    }

    private func store(_ inst: Instruction) throws {
        let p = try place(inst.operands[0])
        if p.root.hasPrefix("<block") { throw error("storing into a uniform block") }
        if let root = scan.root(inst.operands[0]), module.globals[root]?.storage == .input {
            warn("store into input `\(p.root)`")
        }
        let valueId = inst.operands[1]
        // `v.xy = value`: a shuffle of the variable's own value with the new one, written back whole.
        if let s = shuffles[valueId], useCount(valueId) == 1, values[valueId]?.pinned == false,
           s.sourceExpr == p.expr, case .vector(_, let n) = p.type {
            var letters = ""
            var positions: [Int] = []
            var ok = true
            for (i, idx) in s.indices.enumerated() {
                if idx == i { continue }
                if idx >= n { positions.append(i); letters.append(component(i)) } else { ok = false }
            }
            let k = s.indices.filter { $0 >= n }.map { $0 - n }
            if ok, !positions.isEmpty, k == Array(0..<k.count) {
                values[valueId] = nil
                invalidate(p.root)
                emit(.assign(.attr(p.expr, letters), s.value))
                return
            }
        }
        let value = try use(valueId)
        invalidate(p.root)
        emit(.assign(p.expr, value))
    }

    private func call(_ inst: Instruction) throws {
        let calleeId = inst.operands[2]
        guard let callee = module.function(calleeId) else { throw error("call to unknown function %\(calleeId)") }
        let outs = analysis.outParams[calleeId] ?? []
        var args: [PyExpr] = []
        var outPlaces: [Place] = []
        var reads = Set<String>()
        for (k, argId) in inst.operands.dropFirst(3).enumerated() {
            if callee.params[k].type.isPointer {
                let p = try place(argId)
                if outs.contains(k), isNeverWritten(argId) {
                    // A pure `out` argument: whatever goes in is not read, so pass a zero.
                    args.append(ctx.zero(of: p.type))
                } else {
                    args.append(p.expr)
                    reads.formUnion(p.reads)
                }
                if outs.contains(k) { outPlaces.append(p) }
            } else {
                args.append(try use(argId))
                reads.formUnion(self.reads(argId))
            }
        }
        for v in analysis.threaded[calleeId] ?? [] {
            args.append(.name(v.name))
            reads.insert(v.name)
        }
        let expr = PyExpr.call(analysis.name(of: calleeId), args)
        let resultId = inst.operands[1]
        let resultType = module.types[inst.operands[0]] ?? .void

        if outPlaces.isEmpty {
            if resultType == .void {
                emit(.expr(expr))
            } else {
                define(resultId, expr, type: resultType, reads: reads)
            }
            return
        }
        var targets: [PyExpr] = []
        var resultName: String?
        if resultType != .void {
            let name = temp()
            resultName = name
            targets.append(.name(name))
        }
        for p in outPlaces {
            invalidate(p.root)
            targets.append(p.expr)
        }
        emit(.assign(targets.count == 1 ? targets[0] : .tuple(targets), expr))
        if let resultName {
            values[resultId] = ValueEntry(expr: .name(resultName), type: resultType, reads: [resultName], depth: stack.count - 1, pinned: true, remaining: max(useCount(resultId), 1))
        }
    }

    /// A local that nothing stores into and no other call receives: its value at a call is undefined.
    private func isNeverWritten(_ pointer: SpirvId) -> Bool {
        guard let root = scan.root(pointer), let def = scan.defs[root], def.op == .opVariable, def.operands.count == 3,
              !scan.storedRoots.contains(root) else { return false }
        let passes = scan.calls.reduce(0) { $0 + $1.operands.dropFirst(3).filter { scan.root($0) == root }.count }
        return passes == 1
    }

    /// The scalar a `CompositeConstruct` splats, when `id` is one (`constants` includes splatted constants).
    func splatScalar(_ id: SpirvId, _ expr: PyExpr, constants: Bool = false) -> PyExpr? {
        guard case .call(_, let args) = expr, args.count == 1 else { return nil }
        if let d = scan.defs[id], d.op == .opCompositeConstruct, d.operands.count > 3,
           d.operands.dropFirst(2).allSatisfy({ $0 == d.operands[2] }),
           (try? type(of: d.operands[2]))?.isScalar == true {
            return args[0]
        }
        if constants, let c = module.constants[id], case .composite(let ids) = c.value, ids.count > 1,
           ids.allSatisfy({ $0 == ids[0] }), module.constants[ids[0]]?.type.isScalar == true {
            return args[0]
        }
        return nil
    }

    // MARK: - Composite helpers shared with the expression mapping

    func component(_ i: Int) -> String {
        ["x", "y", "z", "w"][min(i, 3)]
    }

    func unpackedName(_ id: SpirvId, _ member: Int) -> String? {
        unpacked[id].flatMap { $0.indices.contains(member) ? $0[member] : nil }
    }

    func rememberShuffle(_ id: SpirvId, source: SpirvId, sourceExpr: PyExpr, value: PyExpr, indices: [Int]) {
        shuffles[id] = (source, sourceExpr, value, indices)
    }

    func absorbedSource(_ id: SpirvId) -> SpirvId? { absorbedExtracts[id] }
}
