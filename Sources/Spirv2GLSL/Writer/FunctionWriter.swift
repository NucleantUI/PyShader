//
//  FunctionWriter.swift
//  Spirv2GLSL
//
//  One SPIR-V function as a GLSL function. Its structured control flow is
//  walked from the entry block: a selection merge is an `if`, a switch an
//  `if` / `else if` chain, a loop a `for` (or `while (true)`), and a branch
//  to the innermost loop's merge or continue target `break` / `continue`,
//  the continue construct written where each `continue` is.
//
//  An SSA value is an expression, written where it is used when it is used
//  once, and otherwise a temporary declared at the top of the function (so
//  it is in scope wherever the value dominates). An expression waiting to
//  be used is written into its temporary first when a store, a call or the
//  end of its block could change what it reads. An OpPhi is a variable
//  each edge into its block assigns.
//

import SpirvCore

/// A value as GLSL: its code, its type and how tightly the code binds.
struct Expr {
    var code: String
    var type: SpirvType
    /// 0 a primary expression (name, literal, call, `.x`, `[i]`); 1 unary;
    /// 2 `*` `/`; 3 `+` `-`; 4 `<` `>`; 5 `==` `!=`; 6 `&&`; 7 `^^`; 8 `||`; 9 `?:`.
    var prec: Int = 0
    /// The variables (roots) the code reads, so a store to one can write it out first.
    var reads: Set<SpirvId> = []
    var hasCall = false
    /// Cheap and side-effect free to write more than once: a name or a literal.
    var isTrivial = false
    /// Made of literals and `for` loop indices only: what GLSL ES 1.00's
    /// Appendix A lets index an array, vector or matrix.
    var isConstantIndex = false
    /// For `vecN(x)`: x (an array, as a struct cannot hold itself).
    var splatParts: [Expr] = []
    /// For `name.xy`, a swizzle of a variable: how many components `name` has.
    var swizzledSize = 0

    /// In `reads`, a call whose result waits to be used: everything that
    /// reads or writes memory, or calls, writes it out first.
    static let callMark: SpirvId = .max

    /// The code, in parentheses unless it binds at least as tightly as `prec`.
    func at(_ prec: Int) -> String {
        self.prec > prec ? "(\(code))" : code
    }
}

/// A pointer as a GLSL place.
struct Place {
    var code: String
    var type: SpirvType
    /// The variable it is rooted in; nil for an input or uniform nothing stores to.
    var root: SpirvId?
    /// A block not yet indexed: its members are separate names.
    var members: (names: [String?], types: [SpirvType], writable: Bool, what: String)?
    var isSampler = false
}

final class LoopContext {
    let header: SpirvId
    let merge: SpirvId
    let continueTarget: SpirvId
    /// The counter a `for` loop counts in, and the name of the for loop's own index.
    let counter: SpirvId?
    let indexName: String?
    /// The counter variable steps beside the for's index, for code after the loop.
    let mirrors: Bool
    var breaks = 0

    init(header: SpirvId, merge: SpirvId, continueTarget: SpirvId, counter: SpirvId? = nil, indexName: String? = nil, mirrors: Bool = false) {
        self.header = header
        self.merge = merge
        self.continueTarget = continueTarget
        self.counter = counter
        self.indexName = indexName
        self.mirrors = mirrors
    }
}

enum Flow { case falls, exits }

private enum Escape { case breakLoop(LoopContext), continueLoop(LoopContext) }

private struct Phi {
    let id: SpirvId
    let type: SpirvType
    let pairs: [(value: SpirvId, parent: SpirvId)]
}

private struct Value {
    var expr: Expr
    var remaining: Int
    /// When it was defined: waiting values are written out in this order.
    var order = 0
}

final class FunctionWriter {
    let stage: StageWriter
    let function: SpirvFunction
    let isEntry: Bool
    var module: SpirvModule { stage.module }
    let scope: NameScope

    private var blocks: [SpirvId: SpirvBlock] = [:]
    private var useCounts: [SpirvId: Int] = [:]
    private var phis: [SpirvId: [Phi]] = [:]
    private var phiNames: [SpirvId: String] = [:]

    private var values: [SpirvId: Value] = [:]
    private var definitions = 0
    private var deferredError: Spirv2GLSLError?
    /// Locals that only ever hold the parameter stored to them first: the parameter itself.
    private var aliases: [SpirvId: SpirvId] = [:]
    /// Vectors built of one scalar repeated (`bvec3(c)`), by id: that scalar.
    var splats: [SpirvId: Expr] = [:]
    /// Scalars computed from constants alone (`RADIUS + 1`), by id.
    var folded: [SpirvId: Folded] = [:]
    private var places: [SpirvId: Place] = [:]
    /// Parameters passed by value, and their names.
    private var params: [SpirvId: Expr] = [:]

    private var lines: [String] = []
    private var indent = 1
    private var declarations: [String] = []
    private var prologue: [String] = []
    private var constantArrays: [SpirvId: String] = [:]
    private(set) var loops: [LoopContext] = []
    private var activeMerges: [SpirvId] = []
    private var skipLoopMergeOf: SpirvId?
    /// The integer or float constant each variable was last set to in the
    /// straight-line code just written: a `for` loop's start.
    private(set) var constantStores: [SpirvId: String] = [:]
    /// The located instruction being written, for errors.
    private(set) var current: Located?

    init(stage: StageWriter, function: SpirvFunction, isEntry: Bool) throws {
        self.stage = stage
        self.function = function
        self.isEntry = isEntry
        self.scope = NameScope(parent: stage.globalScope, mayHide: stage.hideableNames(in: function))
        for b in function.blocks { blocks[b.label] = b }
        countUses()
        try collectPhis()
    }

    func error(_ message: String, at located: Located? = nil) -> Spirv2GLSLError {
        stage.error(message, at: located ?? current)
    }

    // MARK: Writing

    func write() throws -> (prototype: String, body: String) {
        guard case .function(let returns, _) = try module.type(function.functionType) else {
            throw error("function %\(function.id) has no function type", at: function.located)
        }
        if case .array = returns {
            let at = function.blocks.lazy.flatMap(\.body).first { $0.line != nil }
            throw error("`\(module.names[function.id] ?? "a function")` returns an array: OpenGL ES 2 functions cannot return arrays", at: at)
        }
        let name = stage.functionNames[function.id]!
        var paramDecls: [String] = []
        for p in function.params {
            let t = try module.type(p.type)
            let n = scope.unique(module.names[p.id] ?? "p\(p.id)")
            switch t {
            case .pointer(let storage, let pointee):
                switch SpirvStorageClass(rawValue: storage) {
                case .function, .private:
                    paramDecls.append("inout " + (try stage.declaration(n, pointee)))
                    places[p.id] = Place(code: n, type: pointee, root: p.id)
                case .uniformConstant:
                    if case .sampledImage(let dim) = pointee {
                        paramDecls.append("\(try stage.samplerType(dim)) \(n)")
                    } else if case .image(let dim, _, _, _, _) = pointee {
                        paramDecls.append("\(try stage.samplerType(dim)) \(n)")
                    } else {
                        throw error("a parameter pointing at a uniform has no OpenGL ES 2 form", at: function.located)
                    }
                    places[p.id] = Place(code: n, type: pointee, root: nil, isSampler: true)
                default:
                    throw error("a parameter pointing into storage class \(storage) has no OpenGL ES 2 form", at: function.located)
                }
            case .sampledImage(let dim):
                paramDecls.append("\(try stage.samplerType(dim)) \(n)")
                params[p.id] = Expr(code: n, type: t, isTrivial: true)
            default:
                paramDecls.append(try stage.declaration(n, t))
                params[p.id] = Expr(code: n, type: t, isTrivial: true)
            }
        }
        let prototype = isEntry ? "void main()" : "\(try stage.typeName(returns)) \(name)(\(paramDecls.joined(separator: ", ")))"

        aliases = parameterCopies()
        try declareLocals()
        if isEntry { prologue = stage.mainPrologue + prologue }
        guard let first = function.blocks.first else { throw error("function `\(name)` has no blocks", at: function.located) }
        do {
            _ = try emitSequence(from: first.label, pred: nil, stop: nil)
        } catch let e as Spirv2GLSLError {
            if let d = deferredError, (d.line ?? .max) < (e.line ?? .max) { throw d }
            throw e
        }
        if let deferredError { throw deferredError }
        // A `return;` that ends a void function says nothing.
        if returns == .void, lines.last == "    return;" { lines.removeLast() }

        var body = [prototype + " {"]
        body += declarations.map { "    " + $0 }
        body += prologue.map { "    " + $0 }
        body += lines
        body.append("}")
        return (prototype, body.joined(separator: "\n"))
    }

    private func line(_ s: String) {
        lines.append(String(repeating: "    ", count: indent) + s)
    }

    func appendLine(_ s: String) { line(s) }

    func hasPhis(_ label: SpirvId) -> Bool { phis[label] != nil }

    /// Whether `id` is a variable the function declares.
    func isLocal(_ id: SpirvId) -> Bool { module.typeOfLocal(id, in: function) != nil }

    /// The lines `body` writes, one level deeper, and its flow.
    private func capture(_ body: () throws -> Flow) throws -> (lines: [String], flow: Flow) {
        let saved = lines
        lines = []
        indent += 1
        defer { indent -= 1 }
        let flow = try body()
        let out = lines
        lines = saved
        return (out, flow)
    }

    // MARK: Analysis

    private func countUses() {
        for b in function.blocks {
            for i in b.body {
                let skip = Self.resultIndex(i) == 1 ? 2 : 0
                for (k, w) in i.operands.enumerated() where k >= skip {
                    // OpVectorShuffle of a vector with itself reads it once.
                    if i.op == .opVectorShuffle && k == 3 && w == i.operands[2] { continue }
                    useCounts[w, default: 0] += 1
                }
            }
        }
    }

    /// Where an instruction's result id is: 1 after its type, or nil for one with no result.
    static func resultIndex(_ i: Located) -> Int? {
        switch i.op {
        case .opStore, .opBranch, .opBranchConditional, .opSwitch, .opReturn, .opReturnValue, .opKill,
             .opSelectionMerge, .opLoopMerge, .opCopyMemory, .opUnreachable, .opTerminateInvocation,
             .opDemoteToHelperInvocation, .opControlBarrier, .opMemoryBarrier, .opImageWrite, .opNop,
             .opEmitVertex, .opEndPrimitive, .opLine, .opNoLine:
            return nil
        default:
            return 1
        }
    }

    private func collectPhis() throws {
        for b in function.blocks {
            for i in b.body where i.op == .opPhi {
                let o = i.operands
                var pairs: [(SpirvId, SpirvId)] = []
                var k = 2
                while k + 1 < o.count { pairs.append((o[k], o[k + 1])); k += 2 }
                let t = try module.type(o[0])
                phis[b.label, default: []].append(Phi(id: o[1], type: t, pairs: pairs))
                let n = scope.unique(module.names[o[1]] ?? "phi\(o[1])")
                phiNames[o[1]] = n
                declarations.append(try stage.declaration(n, t) + ";")
                values[o[1]] = Value(expr: Expr(code: n, type: t, reads: [o[1]], isTrivial: true), remaining: .max)
            }
        }
    }

    /// The first instruction with a source line that uses `id`: where an
    /// error about a variable declared before any line points.
    private func firstLocated(using id: SpirvId) -> Located? {
        for b in function.blocks {
            for i in b.body where i.line != nil && i.operands.contains(id) { return i }
        }
        return nil
    }

    private func declareLocals() throws {
        for b in function.blocks {
            for i in b.body where i.op == .opVariable {
                do {
                    try declareLocal(i)
                } catch let e as Spirv2GLSLError {
                    // Held until the body is written: the error reported is the one first in the source.
                    let located = e.line == nil ? error(e.message, at: firstLocated(using: i.operands[1])) : e
                    if deferredError == nil || (located.line ?? .max) < (deferredError!.line ?? .max) { deferredError = located }
                    places[i.operands[1]] = Place(code: "v\(i.operands[1])", type: .void, root: i.operands[1])
                }
            }
        }
    }

    /// The locals the entry block sets from a parameter passed by value and
    /// nothing writes again (a compiler's copy of its parameters, so they can
    /// be assigned): each is the parameter, under the parameter's name.
    private func parameterCopies() -> [SpirvId: SpirvId] {
        guard let first = function.blocks.first else { return [:] }
        var chainRoot: [SpirvId: SpirvId] = [:]
        for b in function.blocks {
            for i in b.body where i.op == .opAccessChain || i.op == .opInBoundsAccessChain {
                chainRoot[i.operands[1]] = chainRoot[i.operands[2]] ?? i.operands[2]
            }
        }
        var writes: [SpirvId: Int] = [:]
        for b in function.blocks {
            for i in b.body {
                let o = i.operands
                switch i.op {
                case .opStore?, .opCopyMemory?:
                    writes[chainRoot[o[0]] ?? o[0], default: 0] += 1
                case .opFunctionCall?:
                    for a in o.dropFirst(3) { writes[chainRoot[a] ?? a, default: 0] += 1 }
                default:
                    break
                }
            }
        }
        var out: [SpirvId: SpirvId] = [:]
        for i in first.body where i.op == .opStore {
            let variable = i.operands[0], value = i.operands[1]
            if params[value] != nil, writes[variable] == 1, isLocal(variable), out.values.contains(value) == false {
                out[variable] = value
            }
        }
        return out
    }

    private func declareLocal(_ i: Located) throws {
        let o = i.operands
        guard case .pointer(_, let t) = try module.type(o[0]) else { return }
        if let param = aliases[o[1]], let p = params[param] {
            // Never written: nothing it reads has to be pinned first.
            places[o[1]] = Place(code: p.code, type: t, root: nil)
            return
        }
        let n = scope.unique(module.names[o[1]] ?? "v\(o[1])")
        places[o[1]] = Place(code: n, type: t, root: o[1])
        if o.count > 3 {
            if !stage.containsArray(t), let literal = try stage.constantLiteral(o[3]) {
                declarations.append("\(try stage.declaration(n, t)) = \(literal);")
            } else {
                declarations.append(try stage.declaration(n, t) + ";")
                prologue += try stage.assignConstant(o[3], to: n, type: t)
            }
        } else {
            declarations.append(try stage.declaration(n, t) + ";")
        }
    }

    func block(_ label: SpirvId) throws -> SpirvBlock {
        guard let b = blocks[label] else { throw error("branch to %\(label), which is not a block of the function") }
        return b
    }

    // MARK: Values

    /// A temporary declared at the top of the function.
    func temporary(_ t: SpirvType, hint: SpirvId? = nil) throws -> String {
        let n = scope.unique(hint.flatMap { module.names[$0] } ?? "t")
        declarations.append(try stage.declaration(n, t) + ";")
        return n
    }

    /// Defines `id` as `expr`: kept as an expression for its one use, or
    /// written into a temporary now when used more than once or when it
    /// calls a function, whose side effects must happen here.
    func define(_ id: SpirvId, _ expr: Expr) throws {
        let uses = useCounts[id] ?? 0
        if uses == 0 && !expr.hasCall { return }
        if uses == 0 {
            try flushCalls()
            line(expr.code + ";")
            return
        }
        let isArrayCopy = stage.containsArray(expr.type) && !(expr.isTrivial && expr.reads.isEmpty)
        if (uses > 1 && !expr.isTrivial) || isArrayCopy {
            let n = try temporary(expr.type, hint: id)
            try writeAssignment(to: n, expr.code, type: expr.type)
            values[id] = Value(expr: Expr(code: n, type: expr.type, isTrivial: true), remaining: .max)
        } else {
            definitions += 1
            values[id] = Value(expr: expr, remaining: uses, order: definitions)
        }
    }

    /// `target = code;`, element by element for an array.
    private func writeAssignment(to target: String, _ code: String, type t: SpirvType) throws {
        for s in try stage.assignCopy(from: code, to: target, type: t) { line(s) }
    }

    /// The value `id` as an expression, counting the use.
    func use(_ id: SpirvId) throws -> Expr {
        if var v = values[id] {
            if v.remaining != .max {
                v.remaining -= 1
                if v.remaining <= 0 { values[id] = nil } else { values[id] = v }
            }
            return v.expr
        }
        if let p = params[id] { return p }
        if let c = module.constants[id] {
            let t = try module.type(c.type)
            if let literal = try stage.constantLiteral(id) {
                let negative = literal.hasPrefix("-")
                return Expr(code: literal, type: t, prec: negative ? 1 : 0, isTrivial: true, isConstantIndex: t.isScalar && !t.isBool)
            }
            return Expr(code: try constantArray(id, type: t), type: t, isTrivial: true)
        }
        throw error("%\(id) is used before it is defined, or is not a value")
    }

    /// The value `id` as an expression, without counting a use: to ask its type.
    func use(peek id: SpirvId) throws -> Expr {
        if let v = values[id] { return v.expr }
        if let p = params[id] { return p }
        throw error("%\(id) is used before it is defined, or is not a value")
    }

    /// The array constant `id` in a variable the function fills first.
    private func constantArray(_ id: SpirvId, type t: SpirvType) throws -> String {
        if let n = constantArrays[id] { return n }
        let n = scope.unique(module.names[id] ?? "c")
        declarations.append(try stage.declaration(n, t) + ";")
        prologue += try stage.assignConstant(id, to: n, type: t)
        constantArrays[id] = n
        return n
    }

    /// The value `id`, in a temporary unless it is already cheap to write
    /// more than once.
    func stable(_ id: SpirvId) throws -> Expr {
        let e = try use(id)
        return try stable(e)
    }

    func stable(_ e: Expr) throws -> Expr {
        if e.isTrivial && e.reads.isEmpty { return e }
        let n = try temporary(e.type)
        try writeAssignment(to: n, e.code, type: e.type)
        return Expr(code: n, type: e.type, isTrivial: true)
    }

    /// Writes into temporaries the expressions still waiting that read `root`
    /// (any variable, when nil) or call a function, before something changes it.
    private func flush(reading root: SpirvId?) throws {
        for (id, v) in pendingInOrder() {
            let reads = root.map { v.expr.reads.contains($0) } ?? !v.expr.reads.isEmpty
            if reads || v.expr.reads.contains(Expr.callMark) {
                try pin(id, v)
            }
        }
    }

    /// Writes out the calls whose results wait, so they happen before what comes next.
    func flushCalls() throws {
        for (id, v) in pendingInOrder() where v.expr.reads.contains(Expr.callMark) {
            try pin(id, v)
        }
    }

    /// The values waiting to be used, in the order they were defined.
    private func pendingInOrder() -> [(SpirvId, Value)] {
        values.filter { $0.value.remaining != .max }.sorted { $0.value.order < $1.value.order }.map { ($0.key, $0.value) }
    }

    /// Writes every expression still waiting into its temporary: at the end
    /// of a block, before control moves to blocks that may use it.
    private func materializeAll() throws {
        for (id, v) in pendingInOrder() {
            if v.expr.isTrivial && v.expr.reads.isEmpty { continue }
            try pin(id, v)
        }
    }

    private func pin(_ id: SpirvId, _ v: Value) throws {
        let n = try temporary(v.expr.type, hint: id)
        try writeAssignment(to: n, v.expr.code, type: v.expr.type)
        values[id] = Value(expr: Expr(code: n, type: v.expr.type, isTrivial: true), remaining: .max)
    }

    // MARK: Places

    func place(_ pointer: SpirvId) throws -> Place {
        if let p = places[pointer] { return p }
        guard let ref = stage.globalRefs[pointer] else {
            throw error("%\(pointer) is not a pointer the stage knows")
        }
        switch ref {
        case .variable(let name, let type, let writable):
            return Place(code: name, type: type, root: writable ? pointer : nil)
        case .members(let names, let types, let writable, let what):
            return Place(code: "", type: .void, root: writable ? pointer : nil, members: (names, types, writable, what))
        case .sampler(let name):
            return Place(code: name, type: .sampler, root: nil, isSampler: true)
        case .separateSampler:
            return Place(code: "", type: .sampler, root: nil, isSampler: true)
        }
    }

    private func accessChain(_ i: Located) throws {
        let o = i.operands
        var p = try place(o[2])
        guard case .pointer(_, _) = try module.type(o[0]) else { throw error("an access chain that is not a pointer") }
        var indices = Array(o.dropFirst(3))
        let uniform = p.root == nil && !p.isSampler
        if let members = p.members {
            guard let first = indices.first, let k = module.intConstant(first), members.names.indices.contains(k) else {
                throw error("a block's member must be chosen by a constant")
            }
            guard let n = members.names[k] else {
                throw error("member \(k) of the \(members.what) block has no OpenGL ES 2 form")
            }
            p = Place(code: n, type: members.types[k], root: members.writable ? p.root : nil)
            indices.removeFirst()
        }
        for index in indices {
            switch p.type {
            case .structure(let sid):
                guard let k = module.intConstant(index) else { throw error("a struct member chosen at run time") }
                p.code = p.code + "." + (try stage.memberName(sid, k))
                p.type = try module.members(of: sid)[k]
            case .vector(let c, _):
                if let k = module.intConstant(index) {
                    p.code += "." + Self.component(k)
                } else {
                    p.code += "[\(try indexCode(index, uniform: uniform))]"
                }
                p.type = c
            case .matrix(let column, _):
                p.code += "[\(try indexCode(index, uniform: uniform))]"
                p.type = column
            case .array(let e, _):
                p.code += "[\(try indexCode(index, uniform: uniform))]"
                p.type = e
            default:
                throw error("cannot index into a \(p.type)")
            }
        }
        places[o[1]] = p
    }

    /// An index as code that stays the same while the place is used. Under
    /// Appendix A, one computed at run time may index only a vertex stage's uniforms.
    func indexCode(_ id: SpirvId, uniform: Bool = false) throws -> String {
        if let k = module.intConstant(id) { return "\(k)" }
        let e = try use(id)
        if e.isConstantIndex && e.reads.isEmpty { return e.code }
        if stage.options.loopsFollowAppendixA && !(uniform && stage.stage == .vertex) {
            throw error("an index computed at run time has no OpenGL ES 2 form: GLSL ES 1.00 promises only indices made of constants and for loop indices (its Appendix A)")
        }
        return try stable(e).code
    }

    static func component(_ k: Int) -> String { ["x", "y", "z", "w"][k] }

    // MARK: Control flow

    func emitSequence(from start: SpirvId, pred: SpirvId?, stop: SpirvId?) throws -> Flow {
        if let pred { try phiCopies(from: pred, to: start) }
        var cur = start
        while true {
            let block = try self.block(cur)
            if let m = block.merge, m.op == .opLoopMerge, skipLoopMergeOf != cur {
                let falls = try emitLoop(block)
                constantStores.removeAll()
                guard falls else { return .exits }
                let merge = m.operands[0]
                if merge == stop { return .falls }
                cur = merge
                continue
            }
            if skipLoopMergeOf == cur { skipLoopMergeOf = nil }
            for inst in block.instructions where inst.op != .opPhi && inst.op != .opVariable {
                current = inst
                try emitInstruction(inst)
            }
            let term = block.terminator
            current = term
            switch term.op {
            case .opBranch:
                let t = term.operands[0]
                try materializeAll()
                if t == stop { try phiCopies(from: cur, to: t); return .falls }
                if let escape = escape(t, stop: stop) { try emitEscape(escape, from: cur); return .exits }
                if activeMerges.contains(t) {
                    throw error("a branch out of a construct to an enclosing one's merge has no structured GLSL form")
                }
                try phiCopies(from: cur, to: t)
                cur = t
            case .opBranchConditional:
                let cond = try use(term.operands[0])
                let t = term.operands[1], f = term.operands[2]
                try materializeAll()
                if let m = block.merge, m.op == .opSelectionMerge {
                    let merge = m.operands[0]
                    constantStores.removeAll()
                    let flow = try emitIf(cond, then: t, else: f, from: cur, merge: merge)
                    constantStores.removeAll()
                    if flow == .exits { return .exits }
                    if merge == stop { return .falls }
                    cur = merge
                    continue
                }
                if t == f {
                    if t == stop { try phiCopies(from: cur, to: t); return .falls }
                    try phiCopies(from: cur, to: t)
                    cur = t
                    continue
                }
                // A conditional exit: one side leaves the construct.
                let tExits = t == stop || escape(t, stop: stop) != nil
                let fExits = f == stop || escape(f, stop: stop) != nil
                if tExits && fExits {
                    let a = try capture { try exitEdge(t, from: cur, stop: stop) }
                    let b = try capture { try exitEdge(f, from: cur, stop: stop) }
                    writeIf(cond, a.lines, b.lines)
                    return (a.flow == .exits && b.flow == .exits) ? .exits : .falls
                }
                guard tExits || fExits else {
                    throw error("a conditional branch with no merge that leaves no construct has no structured GLSL form")
                }
                let (exit, stay, negate) = tExits ? (t, f, false) : (f, t, true)
                if exit == stop {
                    // Leaving to the end of the construct: the other side is the rest of it.
                    let a = try capture { try exitEdge(exit, from: cur, stop: stop) }
                    let b = try capture { try emitSequence(from: stay, pred: cur, stop: stop) }
                    writeIf(negate ? not(cond) : cond, a.lines, b.lines)
                    return b.flow == .exits && a.flow == .exits ? .exits : .falls
                }
                let a = try capture { try exitEdge(exit, from: cur, stop: stop) }
                writeIf(negate ? not(cond) : cond, a.lines, [])
                try phiCopies(from: cur, to: stay)
                cur = stay
            case .opSwitch:
                guard let m = block.merge, m.op == .opSelectionMerge else {
                    throw error("a switch with no selection merge")
                }
                let merge = m.operands[0]
                // Each else-if's test runs only when no arm before it did, so a
                // variable's value holds across the chain; anything more is pinned.
                let read = try use(term.operands[0])
                let selector = read.isTrivial ? read : try stable(read)
                try materializeAll()
                constantStores.removeAll()
                let flow = try emitSwitch(selector, term.operands, from: cur, merge: merge)
                constantStores.removeAll()
                if flow == .exits { return .exits }
                if merge == stop { return .falls }
                cur = merge
            case .opReturn:
                try materializeAll()
                line("return;")
                return .exits
            case .opReturnValue:
                let v = try use(term.operands[0])
                try materializeAll()
                line("return \(v.code);")
                return .exits
            case .opKill, .opTerminateInvocation:
                guard stage.stage == .fragment else { throw error("discard in a vertex stage") }
                line("discard;")
                return .exits
            case .opUnreachable:
                return .exits
            default:
                throw error("block %\(cur) ends in \(term.op.map { "\($0)" } ?? "opcode \(term.inst.opcode)"), not a branch or return")
            }
        }
    }

    private func not(_ e: Expr) -> Expr {
        Expr(code: "!" + e.at(0), type: e.type, prec: 1, reads: e.reads)
    }

    private func writeIf(_ cond: Expr, _ thenLines: [String], _ elseLines: [String]) {
        if thenLines.isEmpty && elseLines.isEmpty { return }
        if thenLines.isEmpty {
            line("if (\(not(cond).code)) {")
            lines += elseLines
            line("}")
            return
        }
        line("if (\(cond.code)) {")
        lines += thenLines
        if !elseLines.isEmpty {
            // `} else if (…) {` when the else holds just another if chain.
            let pad = String(repeating: "    ", count: indent + 1)
            if elseLines.first?.hasPrefix(pad + "if (") == true, isSingleIfChain(elseLines, pad: pad) {
                lines.append(String(repeating: "    ", count: indent) + "} else " + elseLines[0].dropFirst(pad.count))
                lines += elseLines.dropFirst().map { String($0.dropFirst(4)) }
                return
            }
            line("} else {")
            lines += elseLines
        }
        line("}")
    }

    /// Whether `lines` is one `if` statement (with its else-ifs) at `pad`'s depth.
    private func isSingleIfChain(_ lines: [String], pad: String) -> Bool {
        for (k, l) in lines.enumerated() where l.hasPrefix(pad) && !l.hasPrefix(pad + " ") {
            let s = l.dropFirst(pad.count)
            if k == 0 { continue }
            if s == "}" { return k == lines.count - 1 }
            if !s.hasPrefix("} else") { return false }
        }
        return false
    }

    private func emitIf(_ cond: Expr, then t: SpirvId, else f: SpirvId, from cur: SpirvId, merge: SpirvId) throws -> Flow {
        activeMerges.append(merge)
        defer { activeMerges.removeLast() }
        let a = try capture { try arm(t, from: cur, merge: merge) }
        constantStores.removeAll()
        let b = try capture { try arm(f, from: cur, merge: merge) }
        writeIf(cond, a.lines, b.lines)
        return (a.flow == .exits && b.flow == .exits) ? .exits : .falls
    }

    private func arm(_ target: SpirvId, from cur: SpirvId, merge: SpirvId) throws -> Flow {
        if target == merge { try phiCopies(from: cur, to: merge); return .falls }
        if let escape = escape(target, stop: merge) { try emitEscape(escape, from: cur); return .exits }
        return try emitSequence(from: target, pred: cur, stop: merge)
    }

    private func exitEdge(_ target: SpirvId, from cur: SpirvId, stop: SpirvId?) throws -> Flow {
        if target == stop { try phiCopies(from: cur, to: target); return .falls }
        try emitEscape(escape(target, stop: stop)!, from: cur)
        return .exits
    }

    private func emitSwitch(_ selector: Expr, _ o: [UInt32], from cur: SpirvId, merge: SpirvId) throws -> Flow {
        guard case .int(let width, _) = selector.type.scalar ?? .void, selector.type.isScalar else {
            throw error("a switch on a \(selector.type)")
        }
        let words = width > 32 ? 2 : 1
        let defaultLabel = o[1]
        var groups: [(label: SpirvId, literals: [String])] = []
        var k = 2
        while k + words < o.count {
            let literalWords = Array(o[k..<(k + words)])
            let label = o[k + words]
            let literal = width > 32 ? "\(Int64(bitPattern: UInt64(literalWords[0]) | UInt64(literalWords[1]) << 32))" : "\(Int32(bitPattern: literalWords[0]))"
            if label != defaultLabel {
                if let g = groups.firstIndex(where: { $0.label == label }) {
                    groups[g].literals.append(literal)
                } else {
                    groups.append((label, [literal]))
                }
            }
            k += words + 1
        }
        activeMerges.append(merge)
        defer { activeMerges.removeLast() }
        var arms: [(cond: String?, lines: [String], flow: Flow)] = []
        for g in groups {
            let cond = g.literals.map { "\(selector.code) == \($0)" }.joined(separator: " || ")
            let a = try capture { try arm(g.label, from: cur, merge: merge) }
            constantStores.removeAll()
            arms.append((cond, a.lines, a.flow))
        }
        let d = try capture { try arm(defaultLabel, from: cur, merge: merge) }
        if !d.lines.isEmpty || groups.isEmpty {
            arms.append((nil, d.lines, d.flow))
        }
        var first = true
        for a in arms {
            if let cond = a.cond {
                line(first ? "if (\(cond)) {" : "} else if (\(cond)) {")
            } else if first {
                lines += a.lines.map { String($0.dropFirst(4)) }
                continue
            } else {
                line("} else {")
            }
            lines += a.lines
            first = false
        }
        if !first { line("}") }
        let hasDefault = arms.last?.cond == nil
        return hasDefault && arms.allSatisfy { $0.flow == .exits } ? .exits : .falls
    }

    private func escape(_ target: SpirvId, stop: SpirvId?) -> Escape? {
        guard let loop = loops.last else { return nil }
        if target == loop.merge { return .breakLoop(loop) }
        if target == loop.continueTarget && target != stop { return .continueLoop(loop) }
        if target == loop.header && target != stop { return .continueLoop(loop) }
        return nil
    }

    private func emitEscape(_ escape: Escape, from cur: SpirvId) throws {
        switch escape {
        case .breakLoop(let loop):
            try phiCopies(from: cur, to: loop.merge)
            loop.breaks += 1
            line("break;")
        case .continueLoop(let loop):
            if loop.continueTarget != loop.header {
                try phiCopies(from: cur, to: loop.continueTarget)
                // A for loop's step is its own, unless the variable keeps stepping beside it.
                if loop.counter == nil || loop.mirrors { _ = try emitContinueConstruct(loop) }
            } else {
                try phiCopies(from: cur, to: loop.header)
            }
            line("continue;")
        }
    }

    /// The continue construct, from the continue target back to the header.
    private func emitContinueConstruct(_ loop: LoopContext) throws -> Flow {
        let saved = loops
        defer { loops = saved }
        return try emitSequence(from: loop.continueTarget, pred: nil, stop: loop.header)
    }

    private func emitLoop(_ header: SpirvBlock) throws -> Bool {
        let m = header.merge!
        current = m
        let merge = m.operands[0], cont = m.operands[1]
        let recognized = try countingLoop(header)
        if case .success(let counting) = recognized {
            // Read after the loop, the variable keeps stepping beside the
            // for's own index; otherwise the index takes the variable's name.
            let index = counting.readAfter ? scope.unique(module.names[counting.counter] ?? "i") : places[counting.counter]!.code
            let typeName = counting.isFloat ? "float" : "int"
            line("for (\(typeName) \(index) = \(counting.start); \(index) \(counting.comparison) \(counting.bound); \(counting.step(index))) {")
            let loop = LoopContext(header: header.label, merge: merge, continueTarget: cont, counter: counting.counter, indexName: index, mirrors: counting.readAfter)
            loops.append(loop)
            indent += 1
            let flow = try emitSequence(from: counting.bodyStart, pred: counting.testBlock, stop: cont)
            if flow == .falls && cont != header.label && loop.mirrors { _ = try emitContinueConstruct(loop) }
            indent -= 1
            loops.removeLast()
            line("}")
            return true
        }
        if stage.options.loopsFollowAppendixA, case .failure(let why) = recognized {
            throw error("this loop has no OpenGL ES 2 form: \(why.value.reason); GLSL ES 1.00 promises only loops that count an int or float from a constant to a constant bound by a constant step (its Appendix A)", at: why.value.at?.line != nil ? why.value.at : m)
        }
        line("while (true) {")
        let loop = LoopContext(header: header.label, merge: merge, continueTarget: cont)
        loops.append(loop)
        indent += 1
        skipLoopMergeOf = header.label
        let flow = try emitSequence(from: header.label, pred: nil, stop: cont == header.label ? header.label : cont)
        if flow == .falls && cont != header.label { _ = try emitContinueConstruct(loop) }
        indent -= 1
        loops.removeLast()
        line("}")
        return loop.breaks > 0
    }

    // MARK: Phis

    private func phiCopies(from pred: SpirvId, to target: SpirvId) throws {
        guard let list = phis[target] else { return }
        var assigns: [(name: String, expr: Expr, type: SpirvType, id: SpirvId)] = []
        for phi in list {
            for pair in phi.pairs where pair.parent == pred {
                assigns.append((phiNames[phi.id]!, try use(pair.value), phi.type, phi.id))
            }
        }
        guard !assigns.isEmpty else { return }
        let targets = Set(list.map(\.id))
        for t in targets { try flush(reading: t) }
        let conflict = assigns.count > 1 && assigns.contains { !$0.expr.reads.isDisjoint(with: targets) }
        if conflict {
            var staged: [(String, String, SpirvType)] = []
            for a in assigns {
                let n = try temporary(a.type)
                try writeAssignment(to: n, a.expr.code, type: a.type)
                staged.append((a.name, n, a.type))
            }
            for (name, n, t) in staged { try writeAssignment(to: name, n, type: t) }
        } else {
            for a in assigns { try writeAssignment(to: a.name, a.expr.code, type: a.type) }
        }
    }

    // MARK: Instructions

    private func emitInstruction(_ i: Located) throws {
        let o = i.operands
        switch i.op {
        case .opLoad:
            let p = try place(o[2])
            let t = try module.type(o[0])
            if p.root != nil { try flushCalls() }
            if p.isSampler {
                values[o[1]] = Value(expr: Expr(code: p.code, type: t, isTrivial: true), remaining: .max)
                return
            }
            if p.members != nil { throw error("reading a whole \(p.members!.what) block has no OpenGL ES 2 form; read its members") }
            if let root = p.root, let loop = loops.last(where: { $0.counter == root }), p.code == places[root]?.code, let index = loop.indexName {
                try define(o[1], Expr(code: index, type: t, isTrivial: true, isConstantIndex: true))
                return
            }
            try define(o[1], Expr(code: p.code, type: t, reads: p.root.map { [$0] } ?? [], isTrivial: true))
        case .opStore:
            // The copy of a parameter into the local that is the parameter.
            if aliases[o[0]] == o[1] { return }
            let p = try place(o[0])
            guard p.members == nil else { throw error("writing a whole block has no OpenGL ES 2 form") }
            let v = try use(o[1])
            if let root = p.root { try flush(reading: root) }
            try writeAssignment(to: p.code, v.code, type: p.type)
            if let root = p.root {
                if p.code == places[root]?.code, let f = foldedValue(o[1]), p.type.isScalar, !p.type.isBool {
                    constantStores[root] = try literal(f)
                } else {
                    constantStores[root] = nil
                }
            }
        case .opCopyMemory:
            let dst = try place(o[0]), src = try place(o[1])
            if let root = dst.root { try flush(reading: root) }
            try writeAssignment(to: dst.code, src.code, type: dst.type)
            if let root = dst.root { constantStores[root] = nil }
        case .opAccessChain, .opInBoundsAccessChain:
            try accessChain(i)
        case .opFunctionCall:
            try call(i)
        case .opCopyObject, .opCopyLogical:
            let e = try use(o[2])
            try define(o[1], e)
        case .opUndef:
            let t = try module.type(o[0])
            try define(o[1], Expr(code: try stage.zeroLiteral(t), type: t, isTrivial: true))
        case .opDemoteToHelperInvocation:
            guard stage.stage == .fragment else { throw error("discard in a vertex stage") }
            line("discard;")
        case .opNop, .opSource, .opName, .opMemberName, .opSourceContinued, .opModuleProcessed:
            return
        default:
            guard let index = Self.resultIndex(i), index == 1, o.count >= 2 else {
                throw error("\(i.op.map { "\($0)" } ?? "opcode \(i.inst.opcode)") has no OpenGL ES 2 form")
            }
            let t = try module.type(o[0])
            if let f = fold(i) {
                folded[o[1]] = f
                let code = try literal(f)
                try define(o[1], Expr(code: code, type: t, prec: code.hasPrefix("-") ? 1 : 0, isTrivial: true, isConstantIndex: true))
                return
            }
            let e = try operation(i, type: t)
            try define(o[1], e)
        }
    }

    private func call(_ i: Located) throws {
        let o = i.operands
        guard let callee = module.functions[o[2]], let name = stage.functionNames[o[2]] else {
            throw error("call of %\(o[2]), which is not a function of the module")
        }
        var args: [String] = []
        for (k, a) in o.dropFirst(3).enumerated() {
            let paramType = try module.type(callee.params[k].type)
            if case .pointer = paramType {
                let p = try place(a)
                if p.members != nil { throw error("passing a whole block has no OpenGL ES 2 form") }
                args.append(p.code)
            } else {
                args.append(try use(a).code)
            }
        }
        // The callee may write through its `inout` parameters and the module's globals, nothing else.
        var changed = Set(stage.writableGlobals)
        for a in o.dropFirst(3) { if let root = places[a]?.root { changed.insert(root) } }
        for root in changed { try flush(reading: root) }
        try flushCalls()
        constantStores.removeAll()
        let t = try module.type(o[0])
        let code = "\(name)(\(args.joined(separator: ", ")))"
        if t == .void {
            line(code + ";")
        } else {
            try define(o[1], Expr(code: code, type: t, reads: [Expr.callMark], hasCall: true))
        }
    }
}
