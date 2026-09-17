//
//  Peepholes.swift
//  Spirv2PyShader
//
//  Rewrites over a function's statement tree that turn the literal
//  translation into the Python a person would write: `while True: if not c:
//  break` into `while c:`, counting loops into `for i in range()`, phi
//  temporaries into `a and b`, single-use copies into their use, `x = x + 1`
//  into `x += 1`, and declarations for variables read before assignment.
//

import PyShader

enum Peepholes {
    static func run(_ body: [PyStmt], locals: [String: ShaderType], params: Set<String>, typeName: (ShaderType) -> String) -> [PyStmt] {
        var stmts = body
        stmts = liftLoopConditions(stmts)
        stmts = mergeComponentStores(stmts, locals: locals)
        stmts = mergePhiSelections(stmts)
        stmts = renameUnpacks(stmts, root: stmts)
        while propagateCopies(&stmts, root: stmts) {}
        stmts = dropDead(stmts, root: stmts)
        while propagateCopies(&stmts, root: stmts) {}
        stmts = augmentAssignments(stmts)
        stmts = forRanges(stmts, root: stmts)
        stmts = dropDead(stmts, root: stmts)
        stmts = declare(stmts, locals: locals, assigned: params, typeName: typeName)
        return stmts
    }

    // MARK: - Loops

    private static func liftLoopConditions(_ stmts: [PyStmt]) -> [PyStmt] {
        stmts.map { s in
            let s = s.withNested(liftLoopConditions)
            guard case .loop(nil, var body, let next) = s, let first = body.first,
                  case .ifStmt(let c, let arm, let orElse) = first, orElse.isEmpty, arm.count == 1, case .breakStmt = arm[0] else { return s }
            body.removeFirst()
            return .loop(cond: .not(c), body: body, next: next)
        }
    }

    // MARK: - Component stores

    /// `v.x = t.x; v.y = t.y; v.z = t.z` -> `v.xyz = t`.
    private static func mergeComponentStores(_ stmts: [PyStmt], locals: [String: ShaderType]) -> [PyStmt] {
        var out: [PyStmt] = []
        var i = 0
        while i < stmts.count {
            let s = stmts[i].withNested { mergeComponentStores($0, locals: locals) }
            guard case .assign(.attr(let target, let c0), .attr(let source, let d0)) = s, c0.count == 1, d0.count == 1 else {
                out.append(s); i += 1; continue
            }
            var targetLetters = c0, sourceLetters = d0
            var j = i + 1
            while j < stmts.count, case .assign(.attr(target, let c), .attr(source, let d)) = stmts[j],
                  c.count == 1, d.count == 1, !targetLetters.contains(c) {
                targetLetters += c
                sourceLetters += d
                j += 1
            }
            if j - i >= 2 {
                var value: PyExpr = .attr(source, sourceLetters)
                if case .name(let n) = source, let t = locals[n], t.componentCount == sourceLetters.count,
                   sourceLetters == String("xyzw".prefix(sourceLetters.count)) {
                    value = source
                }
                out.append(.assign(.attr(target, targetLetters), value))
                i = j
            } else {
                out.append(s)
                i += 1
            }
        }
        return out
    }

    // MARK: - Phis

    /// `_p = a; if a: _p = b` -> `_p = a and b`; `if not a` -> `or`; anything else a
    /// conditional expression. Likewise `if c: _v = a else: _v = b` for a compiler temporary.
    private static func mergePhiSelections(_ stmts: [PyStmt]) -> [PyStmt] {
        var out: [PyStmt] = []
        var i = 0
        while i < stmts.count {
            let s = stmts[i].withNested(mergePhiSelections)
            if case .ifStmt(let cond, let arm, let orElse) = s, arm.count == 1, orElse.count == 1,
               case .assign(.name(let v), let a) = arm[0], case .assign(.name(v), let b) = orElse[0], v.hasPrefix("_v") {
                out.append(.assign(.name(v), .ternary(cond: cond, then: a, else: b)))
                i += 1
                continue
            }
            if i + 1 < stmts.count, case .assign(.name(let p), let a) = s, p.hasPrefix("_p"),
               case .ifStmt(let cond, let arm, let orElse) = stmts[i + 1], orElse.isEmpty, arm.count == 1,
               case .assign(.name(p), let b) = arm[0] {
                let merged: PyExpr
                if cond == a { merged = .boolOp("and", a, b) }
                else if cond == .not(a) { merged = .boolOp("or", a, b) }
                else { merged = .ternary(cond: cond, then: b, else: a) }
                out.append(.assign(.name(p), merged))
                i += 2
                continue
            }
            out.append(s)
            i += 1
        }
        return out
    }

    // MARK: - Copies

    /// `x = E; S(x)` -> `S(E)` when that is x's only read and only write.
    private static func propagateCopies(_ stmts: inout [PyStmt], root: [PyStmt]) -> Bool {
        var i = 0
        while i < stmts.count {
            if case .assign(.name(let x), let e) = stmts[i], i + 1 < stmts.count,
               root.reads(of: x) == 1, root.writes(of: x) == 1,
               let replaced = substitute(x, with: e, in: stmts[i + 1]) {
                stmts.remove(at: i)
                stmts[i] = replaced
                return true
            }
            var changed = false
            stmts[i] = stmts[i].withNested { block in
                var b = block
                if !changed, propagateCopies(&b, root: root) { changed = true }
                return b
            }
            if changed { return true }
            i += 1
        }
        return false
    }

    /// The statement with its one read of `x` replaced, if `x` is read in an expression evaluated once, first.
    private static func substitute(_ x: String, with e: PyExpr, in s: PyStmt) -> PyStmt? {
        func sub(_ expr: PyExpr) -> PyExpr { expr.substituting(x, with: e) }
        switch s {
        case .assign(let t, let v):
            if v.reads(x) == 1 { return .assign(t, sub(v)) }
            if case .name = t { return nil }
            if t.reads(x) == 1, !v.hasCall { return .assign(sub(t), v) }
            return nil
        case .augAssign(let t, let op, let v):
            if v.reads(x) == 1 { return .augAssign(t, op, sub(v)) }
            return nil
        case .expr(let v) where v.reads(x) == 1: return .expr(sub(v))
        case .ret(let v?) where v.reads(x) == 1: return .ret(sub(v))
        case .ifStmt(let c, let t, let f) where c.reads(x) == 1: return .ifStmt(sub(c), t, f)
        case .forRange(let v, let args, let b) where args.reduce(0, { $0 + $1.reads(x) }) == 1:
            return .forRange(v, args.map(sub), b)
        default: return nil
        }
    }

    /// `_t0, _t1 = f(); a = _t0; b = _t1` -> `a, b = f()`.
    private static func renameUnpacks(_ stmts: [PyStmt], root: [PyStmt]) -> [PyStmt] {
        var out: [PyStmt] = []
        var i = 0
        while i < stmts.count {
            let s = stmts[i].withNested { renameUnpacks($0, root: root) }
            guard case .assign(.tuple(var targets), let value) = s else { out.append(s); i += 1; continue }
            var j = i + 1
            while j < stmts.count, case .assign(.name(let y), .name(let t)) = stmts[j],
                  let k = targets.firstIndex(of: .name(t)), root.reads(of: t) == 1, root.writes(of: t) == 1,
                  root.writes(of: y) == 1, !targets.contains(.name(y)) {
                targets[k] = .name(y)
                j += 1
            }
            out.append(.assign(.tuple(targets), value))
            i = j
        }
        return out
    }

    // MARK: - Augmented assignment

    private static let augmentable: Set<String> = ["+", "-", "*", "/", "//", "%", "**", "&", "|", "^", "<<", ">>", "@"]

    private static func augmentAssignments(_ stmts: [PyStmt]) -> [PyStmt] {
        stmts.compactMap { s in
            let s = s.withNested(augmentAssignments)
            guard case .assign(let t, let v) = s else { return s }
            if v == t { return nil }
            if case .binary(let op, let l, let r) = v, l == t, augmentable.contains(op) {
                return .augAssign(t, op, r)
            }
            return s
        }
    }

    // MARK: - for range

    private static func forRanges(_ stmts: [PyStmt], root: [PyStmt]) -> [PyStmt] {
        var out: [PyStmt] = []
        var i = 0
        while i < stmts.count {
            let s = stmts[i].withNested { forRanges($0, root: root) }
            if i + 1 < stmts.count, case .assign(.name(let v), let start) = s, let startValue = start.intValue,
               case .loop(let cond?, let body, let next) = stmts[i + 1].withNested({ forRanges($0, root: root) }),
               let range = rangeArguments(v, start: startValue, cond: cond, next: next, body: body, root: root) {
                out.append(.forRange(v, range, body))
                i += 2
                continue
            }
            out.append(s)
            i += 1
        }
        return out
    }

    private static func rangeArguments(_ v: String, start: Int, cond: PyExpr, next: [PyStmt], body: [PyStmt], root: [PyStmt]) -> [PyExpr]? {
        guard next.count == 1 else { return nil }
        let step: Int
        switch next[0] {
        case .augAssign(.name(v), "+", let e): guard let k = e.intValue else { return nil }; step = k
        case .augAssign(.name(v), "-", let e): guard let k = e.intValue else { return nil }; step = -k
        case .assign(.name(v), .binary("+", .name(v), let e)): guard let k = e.intValue else { return nil }; step = k
        default: return nil
        }
        guard step != 0, case .compare(let op, .name(v), let limit) = cond else { return nil }
        let stop: PyExpr
        switch (op, step > 0) {
        case ("<", true), (">", false): stop = limit
        case ("<=", true): stop = limit.intValue.map { .number("\($0 + 1)") } ?? .binary("+", limit, .number("1"))
        case (">=", false): stop = limit.intValue.map { .number("\($0 - 1)") } ?? .binary("-", limit, .number("1"))
        default: return nil
        }
        // The counter is the loop's alone, and the limit does not move.
        let written = body.writtenNames
        guard !written.contains(v), limit.names.isDisjoint(with: written), !limit.hasCall else { return nil }
        guard root.reads(of: v) == cond.reads(v) + body.reads(of: v) + next.reads(of: v) else { return nil }
        guard root.writes(of: v) == 1 + next.writes(of: v) else { return nil }
        if start == 0, step == 1 { return [stop] }
        if step == 1 { return [.number("\(start)"), stop] }
        return [.number("\(start)"), stop, .number("\(step)")]
    }

    // MARK: - Dead assignments

    private static func dropDead(_ stmts: [PyStmt], root: [PyStmt]) -> [PyStmt] {
        stmts.compactMap { s in
            let s = s.withNested { dropDead($0, root: root) }
            guard case .assign(.name(let x), let v) = s, root.reads(of: x) == 0 else { return s }
            return v.hasCall ? .expr(v) : nil
        }
    }

    // MARK: - Declarations

    /// `name: type` at the top for every local read before it is assigned.
    private static func declare(_ stmts: [PyStmt], locals: [String: ShaderType], assigned: Set<String>, typeName: (ShaderType) -> String) -> [PyStmt] {
        var assigned = assigned
        var needed: [String] = []
        func read(_ e: PyExpr) {
            for n in e.names where locals[n] != nil && !assigned.contains(n) && !needed.contains(n) {
                needed.append(n)
            }
        }
        func walk(_ block: [PyStmt]) {
            for s in block {
                switch s {
                case .assign(let t, let v):
                    read(v)
                    if case .name(let n) = t { assigned.insert(n) }
                    else if case .tuple(let elts) = t {
                        for e in elts { if case .name(let n) = e { assigned.insert(n) } else { read(e) } }
                    } else { read(t) }
                case .augAssign(let t, _, let v):
                    read(t); read(v)
                case .forRange(let v, let args, let body):
                    for a in args { read(a) }
                    assigned.insert(v)
                    walk(body)
                case .loop(let c, let body, let next):
                    if let c { read(c) }
                    walk(body); walk(next)
                case .ifStmt(let c, let t, let f):
                    read(c); walk(t); walk(f)
                default:
                    for e in s.expressions { read(e) }
                }
            }
        }
        walk(stmts)
        var out: [PyStmt] = []
        for n in needed {
            let t = locals[n]!
            if case .array(let elem, let count) = t {
                // A list needs a value to fix its length.
                out.append(.assign(.name(n), .binary("*", .list([zeroLiteral(elem, typeName)]), .number("\(count)"))))
            } else {
                out.append(.declare(n, typeName(t)))
            }
        }
        return out + stmts
    }

    private static func zeroLiteral(_ t: ShaderType, _ typeName: (ShaderType) -> String) -> PyExpr {
        switch t {
        case .scalar(.bool): return .bool(false)
        case .scalar(.float(32)): return .number("0.0")
        case .scalar(.int(32, true)): return .number("0")
        case .scalar(.float): return .call(t.description, [.number("0.0")])
        case .scalar(.int): return .call(t.description, [.number("0")])
        case .vector(let k, _): return .call(t.description, [zeroLiteral(.scalar(k), typeName)])
        case .matrix: return .call(t.description, [.number("0.0")])
        case .array(let e, let n): return .binary("*", .list([zeroLiteral(e, typeName)]), .number("\(n)"))
        case .tuple(let ts): return .tuple(ts.map { zeroLiteral($0, typeName) })
        case .structure(_, let members): return .call(typeName(t), members.map { zeroLiteral($0.1, typeName) })
        default: return .number("0")
        }
    }

    // MARK: - Entry wrapper

    /// PyShader compiles `main` into `py_main` plus a wrapper that only calls
    /// it; when decompiling that, the wrapper goes and the callee is `main`.
    static func collapseWrapper(_ functions: [PyFunction]) -> [PyFunction] {
        guard let entryIndex = functions.firstIndex(where: \.isEntry) else { return functions }
        let entry = functions[entryIndex]
        guard entry.body.count == 1, case .ret(.call(let callee, let args)?) = entry.body[0],
              let calleeIndex = functions.firstIndex(where: { $0.name == callee }), calleeIndex != entryIndex else { return functions }
        // Each argument is one of the wrapper's own parameters, each once.
        let argNames = args.compactMap { arg -> String? in
            if case .name(let n) = arg, entry.params.contains(where: { $0.name == n }) { return n }
            return nil
        }
        guard argNames.count == args.count, Set(argNames).count == argNames.count, argNames.count == entry.params.count else { return functions }
        let inner = functions[calleeIndex]
        guard inner.params.count == args.count, inner.returnType == entry.returnType else { return functions }
        // Called from the wrapper only.
        let calls = functions.enumerated().filter { $0.offset != entryIndex }.reduce(0) { $0 + countCalls(to: callee, in: $1.element.body) }
        guard calls == 0 else { return functions }

        var body = inner.body
        var params = inner.params
        for (k, name) in argNames.enumerated() where inner.params[k].name != name {
            guard !inner.localTypes.keys.contains(name) else { return functions }
            body = rename(inner.params[k].name, to: name, in: body)
            params[k] = (name, inner.params[k].type)
        }
        var out = functions
        out[calleeIndex] = PyFunction(name: entry.name, params: params, returnType: inner.returnType, body: body, isEntry: true, localTypes: inner.localTypes)
        out.remove(at: entryIndex)
        // Entry last.
        let main = out.remove(at: out.firstIndex(where: \.isEntry)!)
        out.append(main)
        return out
    }

    private static func countCalls(to name: String, in stmts: [PyStmt]) -> Int {
        func count(_ e: PyExpr) -> Int {
            var n = 0
            if case .call(name, _) = e { n += 1 }
            return n + e.children.reduce(0) { $0 + count($1) }
        }
        return stmts.reduce(0) { acc, s in
            acc + s.expressions.reduce(0) { $0 + count($1) } + s.nested.reduce(0) { $0 + countCalls(to: name, in: $1) }
        }
    }

    private static func rename(_ from: String, to: String, in stmts: [PyStmt]) -> [PyStmt] {
        stmts.map { s in
            var s = s.mapExpressions { $0.substituting(from, with: .name(to)) }
            switch s {
            case .assign(.name(from), let v): s = .assign(.name(to), v)
            case .augAssign(.name(from), let op, let v): s = .augAssign(.name(to), op, v)
            case .declare(from, let t): s = .declare(to, t)
            case .forRange(from, let a, let b): s = .forRange(to, a, b)
            default: break
            }
            return s.withNested { rename(from, to: to, in: $0) }
        }
    }
}
