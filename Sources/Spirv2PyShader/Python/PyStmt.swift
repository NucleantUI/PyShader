//
//  PyStmt.swift
//  Spirv2PyShader
//
//  Statements of the generated Python, plus the rendering into indented text.
//  `loop` keeps the SPIR-V continue block apart from the body so it can
//  become a `for i in range(...)` or be spliced before each `continue`.
//

indirect enum PyStmt {
    case assign(PyExpr, PyExpr)
    case augAssign(PyExpr, String, PyExpr)
    /// `name: type` — declares a variable read before its first assignment.
    case declare(String, String)
    case expr(PyExpr)
    case ret(PyExpr?)
    case ifStmt(PyExpr, [PyStmt], [PyStmt])
    /// `while cond:` (nil = `while True:`); `next` runs after the body and before every `continue`.
    case loop(cond: PyExpr?, body: [PyStmt], next: [PyStmt])
    case forRange(String, [PyExpr], [PyStmt])
    case breakStmt
    case continueStmt
    case comment(String)

    // MARK: Rendering

    static func render(_ stmts: [PyStmt], indent: Int = 1) -> String {
        var lines: [String] = []
        renderInto(&lines, stmts, indent: indent)
        return lines.joined(separator: "\n")
    }

    private static func renderInto(_ lines: inout [String], _ stmts: [PyStmt], indent: Int) {
        let pad = String(repeating: "    ", count: indent)
        if stmts.isEmpty {
            lines.append(pad + "pass")
            return
        }
        for s in stmts {
            switch s {
            case .assign(let t, let v):
                lines.append("\(pad)\(renderTarget(t)) = \(renderValue(v))")
            case .augAssign(let t, let op, let v):
                lines.append("\(pad)\(renderTarget(t)) \(op)= \(renderValue(v))")
            case .declare(let n, let t):
                lines.append("\(pad)\(n): \(t)")
            case .expr(let e):
                lines.append("\(pad)\(e.rendered)")
            case .ret(let e):
                if let e { lines.append("\(pad)return \(renderValue(e))") } else { lines.append("\(pad)return") }
            case .ifStmt(let c, let t, let e):
                lines.append("\(pad)if \(c.rendered):")
                renderInto(&lines, t, indent: indent + 1)
                var orElse = e
                // elif chains
                while orElse.count == 1, case .ifStmt(let c2, let t2, let e2) = orElse[0] {
                    lines.append("\(pad)elif \(c2.rendered):")
                    renderInto(&lines, t2, indent: indent + 1)
                    orElse = e2
                }
                if !orElse.isEmpty {
                    lines.append("\(pad)else:")
                    renderInto(&lines, orElse, indent: indent + 1)
                }
            case .loop(let cond, let body, let next):
                lines.append("\(pad)while \(cond?.rendered ?? "True"):")
                renderInto(&lines, spliceContinues(body, next) + next, indent: indent + 1)
            case .forRange(let v, let args, let body):
                lines.append("\(pad)for \(v) in range(\(args.map(\.rendered).joined(separator: ", "))):")
                renderInto(&lines, body, indent: indent + 1)
            case .breakStmt:
                lines.append("\(pad)break")
            case .continueStmt:
                lines.append("\(pad)continue")
            case .comment(let text):
                lines.append("\(pad)# \(text)")
            }
        }
    }

    /// Tuple targets and values go bare: `a, b = f()`.
    private static func renderTarget(_ e: PyExpr) -> String {
        if case .tuple(let elts) = e, elts.count > 1 { return elts.map(\.rendered).joined(separator: ", ") }
        return e.rendered
    }

    private static func renderValue(_ e: PyExpr) -> String {
        if case .tuple(let elts) = e, elts.count > 1 { return elts.map(\.rendered).joined(separator: ", ") }
        return e.rendered
    }

    /// Puts the continue block's statements before every `continue` of this loop (not of nested loops).
    private static func spliceContinues(_ body: [PyStmt], _ next: [PyStmt]) -> [PyStmt] {
        if next.isEmpty { return body }
        return body.flatMap { s -> [PyStmt] in
            switch s {
            case .continueStmt: return next + [.continueStmt]
            case .ifStmt(let c, let t, let e): return [.ifStmt(c, spliceContinues(t, next), spliceContinues(e, next))]
            default: return [s]
            }
        }
    }

    // MARK: Traversal

    /// Every expression the statement evaluates directly (not those of nested statements).
    var expressions: [PyExpr] {
        switch self {
        case .assign(let t, let v): return [t, v]
        case .augAssign(let t, _, let v): return [t, v]
        case .expr(let e): return [e]
        case .ret(let e): return e.map { [$0] } ?? []
        case .ifStmt(let c, _, _): return [c]
        case .loop(let c, _, _): return c.map { [$0] } ?? []
        case .forRange(_, let args, _): return args
        case .declare, .breakStmt, .continueStmt, .comment: return []
        }
    }

    var nested: [[PyStmt]] {
        switch self {
        case .ifStmt(_, let t, let e): return [t, e]
        case .loop(_, let b, let n): return [b, n]
        case .forRange(_, _, let b): return [b]
        default: return []
        }
    }

    func withNested(_ f: ([PyStmt]) -> [PyStmt]) -> PyStmt {
        switch self {
        case .ifStmt(let c, let t, let e): return .ifStmt(c, f(t), f(e))
        case .loop(let c, let b, let n): return .loop(cond: c, body: f(b), next: f(n))
        case .forRange(let v, let a, let b): return .forRange(v, a, f(b))
        default: return self
        }
    }

    func mapExpressions(_ f: (PyExpr) -> PyExpr) -> PyStmt {
        switch self {
        case .assign(let t, let v): return .assign(f(t), f(v))
        case .augAssign(let t, let op, let v): return .augAssign(f(t), op, f(v))
        case .expr(let e): return .expr(f(e))
        case .ret(let e): return .ret(e.map(f))
        case .ifStmt(let c, let t, let e): return .ifStmt(f(c), t, e)
        case .loop(let c, let b, let n): return .loop(cond: c.map(f), body: b, next: n)
        case .forRange(let v, let a, let b): return .forRange(v, a.map(f), b)
        default: return self
        }
    }
}

extension Array where Element == PyStmt {
    /// Reads of `name` across the whole tree. Assignment targets count their index
    /// expressions and swizzle/subscript bases (`a.x = 1` reads `a` in the sense
    /// that `a` must already exist).
    func reads(of name: String) -> Int {
        var n = 0
        for s in self {
            switch s {
            case .assign(let t, let v):
                n += v.reads(name) + targetReads(t, name)
            case .augAssign(let t, _, let v):
                n += v.reads(name) + t.reads(name)
            default:
                n += s.expressions.reduce(0) { $0 + $1.reads(name) }
            }
            for block in s.nested { n += block.reads(of: name) }
        }
        return n
    }

    /// Plain-name assignments (`x = ...`, `x += ...`, `for x in`) of `name` across the tree.
    func writes(of name: String) -> Int {
        var n = 0
        for s in self {
            switch s {
            case .assign(let t, _):
                if case .name(name) = t { n += 1 }
                if case .tuple(let elts) = t, elts.contains(.name(name)) { n += 1 }
            case .augAssign(let t, _, _):
                if case .name(name) = t { n += 1 }
            case .forRange(let v, _, _) where v == name:
                n += 1
            default:
                break
            }
            for block in s.nested { n += block.writes(of: name) }
        }
        return n
    }

    /// Variable names the tree writes anywhere, whole or in part.
    var writtenNames: Set<String> {
        var out = Set<String>()
        for s in self {
            switch s {
            case .assign(let t, _):
                if case .tuple(let elts) = t { for e in elts { if let r = e.rootName { out.insert(r) } } }
                else if let r = t.rootName { out.insert(r) }
            case .augAssign(let t, _, _):
                if let r = t.rootName { out.insert(r) }
            case .forRange(let v, _, _):
                out.insert(v)
            default:
                break
            }
            for block in s.nested { out.formUnion(block.writtenNames) }
        }
        return out
    }

    var hasCall: Bool {
        contains { s in s.expressions.contains { $0.hasCall } || s.nested.contains { $0.hasCall } }
    }
}

/// Reads inside an assignment target: `a.x = ...` and `a[i] = ...` read `a`, index expressions are reads.
private func targetReads(_ t: PyExpr, _ name: String) -> Int {
    switch t {
    case .name: return 0
    case .tuple(let elts): return elts.reduce(0) { $0 + targetReads($1, name) }
    default: return t.reads(name)
    }
}
