//
//  PyExpr.swift
//  Spirv2PyShader
//
//  A small Python expression tree and its rendering with the minimum of
//  parentheses Python's precedence table allows.
//

indirect enum PyExpr: Equatable {
    case name(String)
    /// A numeric literal as written (`1.0`, `-3`, `1e-05`).
    case number(String)
    case bool(Bool)
    case call(String, [PyExpr])
    /// `-x`, `not x`, `~x`
    case unary(String, PyExpr)
    /// `+ - * / // % ** @ & | ^ << >>`
    case binary(String, PyExpr, PyExpr)
    /// `< <= > >= == !=`
    case compare(String, PyExpr, PyExpr)
    /// `and` / `or`
    case boolOp(String, PyExpr, PyExpr)
    case attr(PyExpr, String)
    case index(PyExpr, PyExpr)
    case ternary(cond: PyExpr, then: PyExpr, else: PyExpr)
    case tuple([PyExpr])
    case list([PyExpr])

    // MARK: Precedence

    /// Higher binds tighter. Mirrors Python's grammar.
    var precedence: Int {
        switch self {
        case .ternary: return 1
        case .boolOp("or", _, _): return 2
        case .boolOp: return 3
        case .unary("not", _): return 4
        case .compare: return 5
        case .binary("|", _, _): return 6
        case .binary("^", _, _): return 7
        case .binary("&", _, _): return 8
        case .binary("<<", _, _), .binary(">>", _, _): return 9
        case .binary("+", _, _), .binary("-", _, _): return 10
        case .binary("*", _, _), .binary("/", _, _), .binary("//", _, _), .binary("%", _, _), .binary("@", _, _): return 11
        case .unary: return 12
        case .number(let s) where s.hasPrefix("-"): return 12
        case .binary("**", _, _): return 13
        case .binary: return 11
        case .attr, .index, .call: return 14
        case .name, .number, .bool, .tuple, .list: return 15
        }
    }

    // MARK: Rendering

    var rendered: String {
        switch self {
        case .name(let n): return n
        case .number(let s): return s
        case .bool(let b): return b ? "True" : "False"
        case .call(let f, let args):
            return "\(f)(\(args.map(\.rendered).joined(separator: ", ")))"
        case .unary(let op, let e):
            let inner = wrap(e, below: precedence)
            return op == "not" ? "not \(inner)" : "\(op)\(inner)"
        case .binary(let op, let l, let r):
            if op == "**" {
                // right associative; a unary minus on the left needs parens: (-x) ** 2
                return "\(wrap(l, below: precedence + 1)) ** \(wrap(r, below: precedence))"
            }
            return "\(wrap(l, below: precedence)) \(op) \(wrap(r, below: precedence + 1))"
        case .compare(let op, let l, let r):
            // Comparisons chain in Python, so a comparison inside a comparison is always parenthesised.
            return "\(wrap(l, below: precedence + 1)) \(op) \(wrap(r, below: precedence + 1))"
        case .boolOp(let op, let l, let r):
            return "\(wrap(l, below: precedence)) \(op) \(wrap(r, below: precedence))"
        case .attr(let base, let name):
            return "\(wrap(base, below: precedence)).\(name)"
        case .index(let base, let index):
            return "\(wrap(base, below: precedence))[\(index.rendered)]"
        case .ternary(let c, let t, let e):
            return "\(wrap(t, below: precedence + 1)) if \(wrap(c, below: precedence + 1)) else \(wrap(e, below: precedence))"
        case .tuple(let elts):
            if elts.count == 1 { return "(\(elts[0].rendered),)" }
            return "(\(elts.map(\.rendered).joined(separator: ", ")))"
        case .list(let elts):
            return "[\(elts.map(\.rendered).joined(separator: ", "))]"
        }
    }

    private func wrap(_ e: PyExpr, below minimum: Int) -> String {
        var needs = e.precedence < minimum
        // `1.0.x` / `-x.y` are not what we mean.
        if case .attr = self, case .number = e { needs = true }
        return needs ? "(\(e.rendered))" : e.rendered
    }

    // MARK: Traversal

    var children: [PyExpr] {
        switch self {
        case .name, .number, .bool: return []
        case .call(_, let args): return args
        case .unary(_, let e): return [e]
        case .binary(_, let l, let r), .compare(_, let l, let r), .boolOp(_, let l, let r): return [l, r]
        case .attr(let b, _): return [b]
        case .index(let b, let i): return [b, i]
        case .ternary(let c, let t, let e): return [c, t, e]
        case .tuple(let elts), .list(let elts): return elts
        }
    }

    func map(_ f: (PyExpr) -> PyExpr) -> PyExpr {
        switch self {
        case .name, .number, .bool: return self
        case .call(let n, let args): return .call(n, args.map(f))
        case .unary(let op, let e): return .unary(op, f(e))
        case .binary(let op, let l, let r): return .binary(op, f(l), f(r))
        case .compare(let op, let l, let r): return .compare(op, f(l), f(r))
        case .boolOp(let op, let l, let r): return .boolOp(op, f(l), f(r))
        case .attr(let b, let n): return .attr(f(b), n)
        case .index(let b, let i): return .index(f(b), f(i))
        case .ternary(let c, let t, let e): return .ternary(cond: f(c), then: f(t), else: f(e))
        case .tuple(let elts): return .tuple(elts.map(f))
        case .list(let elts): return .list(elts.map(f))
        }
    }

    /// Replaces every read of `name` with `value`.
    func substituting(_ name: String, with value: PyExpr) -> PyExpr {
        if case .name(name) = self { return value }
        return map { $0.substituting(name, with: value) }
    }

    /// How many times `name` is read.
    func reads(_ name: String) -> Int {
        if case .name(name) = self { return 1 }
        return children.reduce(0) { $0 + $1.reads(name) }
    }

    var names: Set<String> {
        if case .name(let n) = self { return [n] }
        return children.reduce(into: Set<String>()) { $0.formUnion($1.names) }
    }

    var hasCall: Bool {
        if case .call = self { return true }
        return children.contains { $0.hasCall }
    }

    /// The variable an assignment target is rooted in (`a.x[i]` -> `a`).
    var rootName: String? {
        switch self {
        case .name(let n): return n
        case .attr(let b, _), .index(let b, _): return b.rootName
        default: return nil
        }
    }

    var isIntLiteral: Bool {
        if case .number(let s) = self { return !s.contains(".") && !s.contains("e") && !s.contains("n") }
        return false
    }

    var intValue: Int? {
        if case .number(let s) = self, isIntLiteral { return Int(s) }
        return nil
    }

    static func not(_ e: PyExpr) -> PyExpr {
        if case .unary("not", let inner) = e { return inner }
        return .unary("not", e)
    }
}
