//
//  GLES2Expressions.swift
//  PyShader
//
//  Expressions as GLSL ES 1.00 text, typed by the same rules the SPIR-V
//  emitter follows: `/` is float division, `//` floors, `%` takes the
//  divisor's sign, ints promote to floats. Every operator is parenthesized,
//  so precedence is never GLSL's to decide.
//

import PySwiftAST

extension GLES2Writer {

    func emitExpression(_ expr: Expression) throws -> GLValue {
        switch expr {
        case .constant(let c):
            return try emitConstant(c)
        case .name(let n):
            return try emitName(n)
        case .binOp(let b):
            if let repeated = try repeatedList(b) { return repeated }
            let l = try emitExpression(b.left)
            let r = try emitExpression(b.right)
            return try binary(b.op, l, r, line: b.lineno)
        case .unaryOp(let u):
            return try emitUnary(u)
        case .boolOp(let b):
            var parts: [String] = []
            for e in b.values { parts.append(try truthy(try emitExpression(e), line: b.lineno).code) }
            return GLValue(code: "(" + parts.joined(separator: b.op == .and ? " && " : " || ") + ")", type: .bool)
        case .compare(let c):
            return try emitCompare(c)
        case .attribute(let a):
            return try emitAttribute(a)
        case .subscriptExpr(let s):
            return try emitSubscript(s)
        case .call(let c):
            return try emitCall(c)
        case .ifExp(let i):
            let cond = try condition(i.test, line: i.lineno)
            let (a, b) = try promote(try emitExpression(i.body), try emitExpression(i.orElse), line: i.lineno)
            if case .array = a.type {
                throw PyShaderError("OpenGL ES 2 cannot pick between two lists with `if … else`", line: i.lineno)
            }
            return GLValue(code: "(\(cond.code) ? \(a.code) : \(b.code))", type: a.type)
        case .lambda(let l):
            throw PyShaderError("lambdas must be bound to a module-level name before use", line: l.lineno)
        case .tuple(let t):
            guard !t.elts.isEmpty else { throw PyShaderError("empty tuple", line: t.lineno) }
            let values = try t.elts.map { try emitExpression($0) }
            for v in values where !v.type.isStorable {
                throw PyShaderError("cannot put a `\(v.type)` in a tuple", line: t.lineno)
            }
            let type = ShaderType.tuple(values.map(\.type))
            return GLValue(code: "\(try typeName(type, line: t.lineno))(\(values.map(\.code).joined(separator: ", ")))", type: type)
        case .list(let l):
            return try emitListLiteral(l.elts, line: l.lineno)
        case .dict(let d):
            throw PyShaderError("dicts are not available in shader code", line: d.lineno)
        case .set(let s):
            throw PyShaderError("sets are not available in shader code", line: s.lineno)
        case .joinedStr(let j):
            throw PyShaderError("strings are not available in shader code", line: j.lineno)
        case .namedExpr(let n):
            throw PyShaderError("walrus assignments are not supported", line: n.lineno)
        case .listComp(let l):
            throw PyShaderError("comprehensions are not available in shader code", line: l.lineno)
        case .await(let a):
            throw PyShaderError("await is not available in shader code", line: a.lineno)
        default:
            throw PyShaderError("unsupported expression", line: expr.lineno)
        }
    }

    // MARK: Leaves

    static func intLiteral(_ v: Int) -> String {
        v < 0 ? "(\(v))" : "\(v)"
    }

    static func floatLiteral(_ v: Double) -> String {
        var s: String
        if v.isFinite, v == v.rounded(), abs(v) < 1e15 {
            s = "\(Int64(v)).0"
        } else {
            s = "\(v)"
            if !s.contains(".") && !s.contains("e") { s += ".0" }
        }
        return v < 0 || s.hasPrefix("-") ? "(\(s))" : s
    }

    static func literal(_ l: GLLiteral, type: ShaderType) -> GLValue {
        switch l {
        case .int(let v): return GLValue(code: intLiteral(v), type: type, literal: l, isConstantIndex: true)
        case .float(let v): return GLValue(code: floatLiteral(v), type: type, literal: l, isConstantIndex: true)
        case .bool(let v): return GLValue(code: v ? "true" : "false", type: type, literal: l, isConstantIndex: true)
        }
    }

    private func emitConstant(_ c: Constant) throws -> GLValue {
        switch c.value {
        case .int(let v): return Self.literal(.int(v), type: .int)
        case .float(let v): return Self.literal(.float(v), type: .float)
        case .bool(let v): return Self.literal(.bool(v), type: .bool)
        case .none: throw PyShaderError("`None` is not a value in shader code", line: c.lineno)
        case .string, .bytes: throw PyShaderError("strings are not available in shader code", line: c.lineno)
        case .complex: throw PyShaderError("complex numbers are not available in shader code", line: c.lineno)
        case .ellipsis: throw PyShaderError("`...` is not a value", line: c.lineno)
        }
    }

    private func emitName(_ n: Name) throws -> GLValue {
        if let gl = counter(n.id) {
            return GLValue(code: gl, type: .int, isConstantIndex: true)
        }
        if let local = lookupLocal(n.id) {
            return GLValue(code: local.name, type: local.type)
        }
        if let handle = lookupHandle(n.id), case .sampledImage = handle {
            throw PyShaderError("`\(n.id)` is a texture; sample it as `\(n.id)(uv)`", line: n.lineno)
        }
        if let v = try lookupVariable(n.id, line: n.lineno) {
            return GLValue(code: v.name, type: v.type)
        }
        if let global = program.globals[n.id] {
            return try compiler.withGlobalInlining(n.id, line: n.lineno) {
                try PyShaderError.attributing(to: program.origin(of: n.id)) { try emitExpression(global.expr) }
            }
        }
        if program.lambdas[n.id] != nil || program.functions[n.id] != nil {
            throw PyShaderError("`\(n.id)` is a function; call it", line: n.lineno)
        }
        if ShaderType.named(n.id) != nil || program.structs[n.id] != nil {
            throw PyShaderError("`\(n.id)` is a type; call it to construct a value", line: n.lineno)
        }
        if let constant = BuiltinConstants.value(named: n.id) {
            return Self.literal(.float(constant), type: .float)
        }
        if let size = try compiler.textureSize(named: n.id, from: self, line: n.lineno) {
            return size
        }
        if compiler.texture(named: n.id) != nil {
            throw PyShaderError("`\(n.id)` is a texture; sample it as `\(n.id)(uv)`", line: n.lineno)
        }
        if wasCounter(n.id) {
            throw PyShaderError("`\(n.id)` is the counter of a loop above; an OpenGL ES 2 loop counter exists only inside its loop", line: n.lineno)
        }
        throw PyShaderError("`\(n.id)` is not defined", line: n.lineno)
    }

    // MARK: Lists

    /// `[a, b, c]`: GLSL ES 1.00 has no array constructor, so the list is a
    /// local filled element by element.
    private func emitListLiteral(_ elts: [Expression], line: Int) throws -> GLValue {
        guard !elts.isEmpty else { throw PyShaderError("a list needs at least one element to fix its type", line: line) }
        let values = try elts.map { try emitExpression($0) }
        let element = values[0].type
        guard element.isStorable else { throw PyShaderError("cannot put a `\(element)` in a list", line: line) }
        if case .array = element { throw PyShaderError("OpenGL ES 2 has no lists of lists", line: line) }
        let type = ShaderType.array(element, values.count)
        let name = try temp(type, line: line)
        for (i, v) in values.enumerated() {
            self.line("\(name)[\(i)] = \(try coerce(v, to: element, line: line).code);")
        }
        return GLValue(code: name, type: type)
    }

    /// `[x] * n` / `n * [x]`.
    private func repeatedList(_ b: BinOp) throws -> GLValue? {
        guard b.op == .mult else { return nil }
        let (listExpr, countExpr): (Expression, Expression)
        if case .list = b.left { (listExpr, countExpr) = (b.left, b.right) }
        else if case .list = b.right { (listExpr, countExpr) = (b.right, b.left) }
        else { return nil }
        guard let n = constantIndex(countExpr), n > 0 else {
            throw PyShaderError("list repeat count must be a positive constant", line: b.lineno)
        }
        let base = try emitExpression(listExpr)
        guard case .array(let element, let m) = base.type else { return nil }
        let type = ShaderType.array(element, n * m)
        let name = try temp(type, line: b.lineno)
        for k in 0..<(n * m) {
            line("\(name)[\(k)] = \(base.code)[\(k % m)];")
        }
        return GLValue(code: name, type: type)
    }

    /// A list converted element by element into a new local.
    func coerceArray(_ v: GLValue, to target: ShaderType, line: Int) throws -> GLValue {
        guard case .array(_, let n) = v.type, case .array(_, let m) = target, n == m else {
            throw PyShaderError("cannot convert `\(v.type)` to `\(target)`", line: line)
        }
        let name = try temp(target, line: line)
        try store(code: name, type: target, v, line: line)
        return GLValue(code: name, type: target)
    }

    // MARK: Unary / boolean

    private func emitUnary(_ u: UnaryOp) throws -> GLValue {
        let v = try emitExpression(u.operand)
        switch u.op {
        case .uAdd:
            guard v.type.isNumeric else { throw PyShaderError("unary + needs a number", line: u.lineno) }
            return v
        case .uSub:
            guard v.type.isNumeric else { throw PyShaderError("unary - needs a number", line: u.lineno) }
            switch v.literal {
            case .int(let k): return Self.literal(.int(-k), type: v.type)
            case .float(let k): return Self.literal(.float(-k), type: v.type)
            default: return GLValue(code: "(-\(v.code))", type: v.type, isConstantIndex: v.isConstantIndex)
            }
        case .not:
            let b = try truthy(v, line: u.lineno)
            return GLValue(code: "(!\(b.code))", type: .bool)
        case .invert:
            throw PyShaderError("OpenGL ES 2 has no bitwise operators (`~`)", line: u.lineno)
        }
    }

    /// Bools pass; numbers compare to zero.
    func truthy(_ v: GLValue, line: Int) throws -> GLValue {
        if v.type == .bool { return v }
        guard v.type.isScalar, v.type.isNumeric else {
            throw PyShaderError("condition must be a scalar bool or number, got `\(v.type)` (use any()/all() for vectors)", line: line)
        }
        return GLValue(code: "(\(v.code) != \(v.type.isFloat ? "0.0" : "0"))", type: .bool)
    }

    // MARK: Comparisons

    private func emitCompare(_ c: Compare) throws -> GLValue {
        var left = try emitExpression(c.left)
        var parts: [GLValue] = []
        for (op, rightExpr) in zip(c.ops, c.comparators) {
            let right = try emitExpression(rightExpr)
            let cmp = try compare(op, left, right, line: c.lineno)
            if !parts.isEmpty, cmp.type != .bool || parts[0].type != .bool {
                throw PyShaderError("chained comparisons only work on scalars", line: c.lineno)
            }
            parts.append(cmp)
            left = right
        }
        if parts.count == 1 { return parts[0] }
        return GLValue(code: "(" + parts.map(\.code).joined(separator: " && ") + ")", type: .bool)
    }

    func compare(_ op: CmpOp, _ l: GLValue, _ r: GLValue, line: Int) throws -> GLValue {
        let (a, b) = try promote(l, r, line: line)
        let kind = a.type.scalarKind!
        let n = a.type.componentCount
        let symbol: String
        let function: String
        switch (op, kind) {
        case (.eq, _): (symbol, function) = ("==", "equal")
        case (.notEq, _): (symbol, function) = ("!=", "notEqual")
        case (.lt, .float), (.lt, .int): (symbol, function) = ("<", "lessThan")
        case (.ltE, .float), (.ltE, .int): (symbol, function) = ("<=", "lessThanEqual")
        case (.gt, .float), (.gt, .int): (symbol, function) = (">", "greaterThan")
        case (.gtE, .float), (.gtE, .int): (symbol, function) = (">=", "greaterThanEqual")
        case (.is, _), (.isNot, _):
            throw PyShaderError("`is` is not meaningful in shader code; use == / !=", line: line)
        case (.in, _), (.notIn, _):
            throw PyShaderError("`in` is not available in shader code", line: line)
        default:
            throw PyShaderError("cannot order `\(a.type)` values", line: line)
        }
        if n == 1 { return GLValue(code: "(\(a.code) \(symbol) \(b.code))", type: .bool) }
        return GLValue(code: "\(function)(\(a.code), \(b.code))", type: .bool(n))
    }

    // MARK: Arithmetic

    func binary(_ op: Operator, _ l: GLValue, _ r: GLValue, line: Int) throws -> GLValue {
        if l.type.isMatrix || r.type.isMatrix {
            return try matrixBinary(op, l, r, line: line)
        }
        if op == .matMult {
            let (a, b) = try promote(l, r, line: line, forceFloat: true)
            guard a.type.isVector else { throw PyShaderError("`@` needs vectors or matrices", line: line) }
            return GLValue(code: "dot(\(a.code), \(b.code))", type: a.type.elementType!)
        }
        if l.type.isBool && r.type.isBool, [.bitAnd, .bitOr, .bitXor].contains(op) {
            let (a, b) = try promote(l, r, line: line)
            if a.type.isScalar {
                let symbol = op == .bitAnd ? "&&" : op == .bitOr ? "||" : "^^"
                return GLValue(code: "(\(a.code) \(symbol) \(b.code))", type: .bool)
            }
            // Logical operators take only scalars in GLSL ES 1.00: through 0/1 floats.
            let n = a.type.componentCount
            switch op {
            case .bitAnd: return GLValue(code: "bvec\(n)(vec\(n)(\(a.code)) * vec\(n)(\(b.code)))", type: a.type)
            case .bitOr: return GLValue(code: "bvec\(n)(max(vec\(n)(\(a.code)), vec\(n)(\(b.code))))", type: a.type)
            default: return GLValue(code: "notEqual(\(a.code), \(b.code))", type: a.type)
            }
        }
        guard l.type.isNumeric, r.type.isNumeric else {
            throw PyShaderError("cannot apply `\(symbol(op))` to `\(l.type)` and `\(r.type)`", line: line)
        }
        switch op {
        case .mult:
            // A float vector times a scalar needs no splat.
            if let (vec, scalar) = vectorTimesScalar(l, r) {
                let s = try coerce(scalar, to: vec.type.elementType!, line: line)
                return GLValue(code: "(\(vec.code) * \(s.code))", type: vec.type)
            }
            return try arithmetic("*", try promote(l, r, line: line))
        case .add:
            return try arithmetic("+", try promote(l, r, line: line))
        case .sub:
            return try arithmetic("-", try promote(l, r, line: line))
        case .div:
            let (a, b) = try promote(l, r, line: line, forceFloat: true)
            return GLValue(code: "(\(a.code) / \(b.code))", type: a.type)
        case .floorDiv:
            let (a, b) = try promote(l, r, line: line)
            if a.type.isFloat { return GLValue(code: "floor(\(a.code) / \(b.code))", type: a.type) }
            if case .int(let x) = a.literal, case .int(let y) = b.literal, y != 0 {
                return Self.literal(.int(Int((Double(x) / Double(y)).rounded(.down))), type: a.type)
            }
            // GLSL ES 1.00 ints may be floats underneath; floor of the float quotient is Python's `//`.
            let fa = try convert(a, to: a.type.withKind(.float(bits: 32)), line: line)
            let fb = try convert(b, to: b.type.withKind(.float(bits: 32)), line: line)
            return GLValue(code: "\(try typeName(a.type, line: line))(floor(\(fa.code) / \(fb.code)))", type: a.type, isConstantIndex: a.isConstantIndex && b.isConstantIndex)
        case .mod:
            let (a, b) = try promote(l, r, line: line)
            if a.type.isFloat { return GLValue(code: "mod(\(a.code), \(b.code))", type: a.type) }
            if case .int(let x) = a.literal, case .int(let y) = b.literal, y != 0 {
                return Self.literal(.int(((x % y) + y) % y), type: a.type)
            }
            // GLSL's `mod` takes the divisor's sign, as Python's `%` does.
            let fa = try convert(a, to: a.type.withKind(.float(bits: 32)), line: line)
            let fb = try convert(b, to: b.type.withKind(.float(bits: 32)), line: line)
            return GLValue(code: "\(try typeName(a.type, line: line))(mod(\(fa.code), \(fb.code)))", type: a.type, isConstantIndex: a.isConstantIndex && b.isConstantIndex)
        case .pow:
            let (a, b) = try promote(l, r, line: line, forceFloat: true)
            return GLValue(code: "pow(\(a.code), \(b.code))", type: a.type)
        case .bitAnd, .bitOr, .bitXor, .lShift, .rShift:
            throw PyShaderError("OpenGL ES 2 has no bitwise operators (`\(symbol(op))`)", line: line)
        case .matMult:
            throw PyShaderError("`@` needs vectors or matrices", line: line)
        }
    }

    /// `(a op b)`, folded when both are literals.
    private func arithmetic(_ op: String, _ operands: (GLValue, GLValue)) throws -> GLValue {
        let (a, b) = operands
        switch (a.literal, b.literal) {
        case (.int(let x), .int(let y)):
            let v = op == "+" ? x &+ y : op == "-" ? x &- y : x &* y
            return Self.literal(.int(v), type: a.type)
        case (.float(let x), .float(let y)):
            let v = op == "+" ? x + y : op == "-" ? x - y : x * y
            return Self.literal(.float(v), type: a.type)
        default:
            return GLValue(code: "(\(a.code) \(op) \(b.code))", type: a.type, isConstantIndex: a.isConstantIndex && b.isConstantIndex)
        }
    }

    private func vectorTimesScalar(_ l: GLValue, _ r: GLValue) -> (GLValue, GLValue)? {
        func fits(_ vec: GLValue, _ s: GLValue) -> Bool {
            vec.type.isVector && vec.type.isFloat && s.type.isScalar && (s.type.isInt || s.type.isFloat)
        }
        if fits(l, r) { return (l, r) }
        if fits(r, l) { return (r, l) }
        return nil
    }

    func symbol(_ op: Operator) -> String {
        switch op {
        case .add: return "+"
        case .sub: return "-"
        case .mult: return "*"
        case .matMult: return "@"
        case .div: return "/"
        case .mod: return "%"
        case .pow: return "**"
        case .lShift: return "<<"
        case .rShift: return ">>"
        case .bitOr: return "|"
        case .bitXor: return "^"
        case .bitAnd: return "&"
        case .floorDiv: return "//"
        }
    }

    // MARK: Matrices

    private func matrixBinary(_ op: Operator, _ l: GLValue, _ r: GLValue, line: Int) throws -> GLValue {
        switch op {
        case .mult, .matMult:
            switch (l.type, r.type) {
            case (.matrix(let k, let lc, let lr), .matrix(let rk, let rc, let rr)):
                guard lc == rr else { throw PyShaderError("cannot multiply `\(l.type)` by `\(r.type)`", line: line) }
                guard k == rk else { throw PyShaderError("cannot mix `\(k.name)` and `\(rk.name)` matrices", line: line) }
                return GLValue(code: "(\(l.code) * \(r.code))", type: .matrix(k, columns: rc, rows: lr))
            case (.matrix(let k, let cols, let rows), .vector):
                let v = try coerce(r, to: .vector(k, cols), line: line)
                return GLValue(code: "(\(l.code) * \(v.code))", type: .vector(k, rows))
            case (.vector, .matrix(let k, let cols, let rows)):
                let v = try coerce(l, to: .vector(k, rows), line: line)
                return GLValue(code: "(\(v.code) * \(r.code))", type: .vector(k, cols))
            case (.matrix(let k, _, _), .scalar):
                let s = try coerce(r, to: .scalar(k), line: line)
                return GLValue(code: "(\(l.code) * \(s.code))", type: l.type)
            case (.scalar, .matrix(let k, _, _)):
                let s = try coerce(l, to: .scalar(k), line: line)
                return GLValue(code: "(\(s.code) * \(r.code))", type: r.type)
            default:
                throw PyShaderError("cannot multiply `\(l.type)` by `\(r.type)`", line: line)
            }
        case .add, .sub:
            guard l.type.isMatrix, l.type == r.type else {
                throw PyShaderError("cannot apply `\(symbol(op))` to `\(l.type)` and `\(r.type)`", line: line)
            }
            return GLValue(code: "(\(l.code) \(symbol(op)) \(r.code))", type: l.type)
        case .div:
            guard case .matrix(let k, _, _) = l.type, r.type.isScalar, r.type.isNumeric else {
                throw PyShaderError("a matrix can only be divided by a scalar", line: line)
            }
            let s = try coerce(r, to: .scalar(k), line: line)
            return GLValue(code: "(\(l.code) / \(s.code))", type: l.type)
        default:
            throw PyShaderError("cannot apply `\(symbol(op))` to matrices", line: line)
        }
    }

    /// `float3x3()` identity, `float3x3(s)` diagonal, `float3x3(m)` resized
    /// (identity-filled), columns, or components column-major.
    private func constructMatrix(_ type: ShaderType, _ args: [GLValue], line: Int) throws -> GLValue {
        guard case .matrix(let k, let cols, let rows) = type else { preconditionFailure() }
        let name = try typeName(type, line: line)
        let element = ShaderType.scalar(k)
        if args.isEmpty {
            return GLValue(code: "\(name)(1.0)", type: type)
        }
        if args.count == 1, args[0].type.isScalar {
            return GLValue(code: "\(name)(\(try convert(args[0], to: element, line: line).code))", type: type)
        }
        if args.count == 1, case .matrix(let mk, let mc, let mr) = args[0].type {
            guard mk == k else { throw PyShaderError("cannot convert `\(args[0].type)` to `\(type)`", line: line) }
            // GLSL ES 1.00 builds no matrix from a matrix: column by column.
            let m = try materialize(args[0], line: line)
            var columns: [String] = []
            for c in 0..<cols {
                var components: [String] = []
                for r in 0..<rows {
                    components.append(c < mc && r < mr ? "\(m.code)[\(c)][\(r)]" : (r == c ? "1.0" : "0.0"))
                }
                columns.append("vec\(rows)(\(components.joined(separator: ", ")))")
            }
            return GLValue(code: "\(name)(\(columns.joined(separator: ", ")))", type: type)
        }
        if args.count == cols, args.allSatisfy({ $0.type.isVector }) {
            let columns = try args.map { try coerce($0, to: .vector(k, rows), line: line).code }
            return GLValue(code: "\(name)(\(columns.joined(separator: ", ")))", type: type)
        }
        var count = 0
        var parts: [String] = []
        for a in args {
            guard a.type.isScalar || a.type.isVector else {
                throw PyShaderError("cannot build `\(type)` from `\(a.type)`", line: line)
            }
            count += a.type.componentCount
            parts.append(try convert(a, to: a.type.withKind(k), line: line).code)
        }
        guard count == cols * rows else {
            throw PyShaderError("`\(type)` needs \(cols * rows) components, got \(count)", line: line)
        }
        return GLValue(code: "\(name)(\(parts.joined(separator: ", ")))", type: type)
    }

    // MARK: Promotion and conversion

    /// Two operands brought to one type, as the SPIR-V emitter does.
    func promote(_ l: GLValue, _ r: GLValue, line: Int, forceFloat: Bool = false) throws -> (GLValue, GLValue) {
        guard let lk = l.type.scalarKind, let rk = r.type.scalarKind else {
            throw PyShaderError("cannot combine `\(l.type)` and `\(r.type)`", line: line)
        }
        var kind = try unify(lk, rk, line: line)
        if forceFloat, case .int = kind { kind = .float(bits: 32) }
        let ln = l.type.componentCount, rn = r.type.componentCount
        let n: Int
        if ln == rn { n = ln }
        else if ln == 1 { n = rn }
        else if rn == 1 { n = ln }
        else { throw PyShaderError("cannot combine `\(l.type)` and `\(r.type)`", line: line) }
        let target: ShaderType = n == 1 ? .scalar(kind) : .vector(kind, n)
        return (try coerce(l, to: target, line: line), try coerce(r, to: target, line: line))
    }

    private func unify(_ a: ScalarKind, _ b: ScalarKind, line: Int) throws -> ScalarKind {
        if a == b { return a }
        switch (a, b) {
        case (.bool, _), (_, .bool):
            throw PyShaderError("cannot combine `\(a.name)` and `\(b.name)`", line: line)
        case (.float(let x), .float(let y)):
            return .float(bits: max(x, y))
        case (.float, .int):
            return a
        case (.int, .float):
            return b
        case (.int(let x, let sx), .int(let y, let sy)):
            guard sx == sy else {
                throw PyShaderError("cannot mix `\(a.name)` and `\(b.name)`; convert one explicitly", line: line)
            }
            return .int(bits: max(x, y), signed: sx)
        }
    }

    /// Implicit conversion: int -> float, narrow -> wide, scalar -> vector.
    func coerce(_ v: GLValue, to target: ShaderType, line: Int) throws -> GLValue {
        if v.type == target { return v }
        if case .tuple(let from) = v.type, case .tuple(let to) = target, from.count == to.count {
            let source = try materialize(v, line: line)
            var parts: [String] = []
            for (i, (f, t)) in zip(from, to).enumerated() {
                parts.append(try coerce(GLValue(code: "\(source.code).m\(i)", type: f), to: t, line: line).code)
            }
            return GLValue(code: "\(try typeName(target, line: line))(\(parts.joined(separator: ", ")))", type: target)
        }
        if case .array = v.type, case .array = target {
            return try coerceArray(v, to: target, line: line)
        }
        guard let fromKind = v.type.scalarKind, let toKind = target.scalarKind else {
            throw PyShaderError("cannot convert `\(v.type)` to `\(target)`", line: line)
        }
        let fromN = v.type.componentCount, toN = target.componentCount
        if fromN != toN {
            guard fromN == 1 else {
                throw PyShaderError("cannot convert `\(v.type)` to `\(target)`", line: line)
            }
            let scalar = try coerce(v, to: .scalar(toKind), line: line)
            return GLValue(code: "\(try typeName(target, line: line))(\(scalar.code))", type: target)
        }
        switch (fromKind, toKind) {
        case (.int, .float):
            if case .int(let k) = v.literal { return Self.literal(.float(Double(k)), type: target) }
            return GLValue(code: "\(try typeName(target, line: line))(\(v.code))", type: target)
        case (.float, .float):
            return GLValue(code: v.code, type: target, literal: v.literal, isConstantIndex: v.isConstantIndex)
        case (.int(let fb, let fs), .int(let tb, let ts)):
            guard fs == ts else {
                throw PyShaderError("cannot implicitly convert `\(v.type)` to `\(target)`; use \(target)(...)", line: line)
            }
            guard tb >= fb else {
                throw PyShaderError("cannot implicitly narrow `\(v.type)` to `\(target)`; use \(target)(...)", line: line)
            }
            _ = try typeName(target, line: line)
            return GLValue(code: v.code, type: target, literal: v.literal, isConstantIndex: v.isConstantIndex)
        case (.float, .int):
            throw PyShaderError("cannot implicitly convert `\(v.type)` to `\(target)`; use \(target)(...)", line: line)
        default:
            throw PyShaderError("cannot convert `\(v.type)` to `\(target)`", line: line)
        }
    }

    /// Explicit conversion, as `float(x)`, `int(x)`, `bool(x)` do: GLSL's own constructors.
    func convert(_ v: GLValue, to target: ShaderType, line: Int) throws -> GLValue {
        if v.type == target { return v }
        guard let fromKind = v.type.scalarKind, let toKind = target.scalarKind else {
            throw PyShaderError("cannot convert `\(v.type)` to `\(target)`", line: line)
        }
        let name = try typeName(target, line: line)
        guard v.type.componentCount == target.componentCount else {
            if v.type.isScalar {
                let s = try convert(v, to: .scalar(toKind), line: line)
                return GLValue(code: "\(name)(\(s.code))", type: target)
            }
            throw PyShaderError("cannot convert `\(v.type)` to `\(target)`", line: line)
        }
        switch (fromKind, toKind, v.literal) {
        case (.float, .float, _), (.int, .int, _):
            return GLValue(code: v.code, type: target, literal: v.literal, isConstantIndex: v.isConstantIndex)
        case (.int, .float, .int(let k)?):
            return Self.literal(.float(Double(k)), type: target)
        case (.float, .int, .float(let k)?) where k.isFinite && abs(k) < 1e15:
            return Self.literal(.int(Int(k.rounded(.towardZero))), type: target)
        default:
            return GLValue(code: "\(name)(\(v.code))", type: target, isConstantIndex: v.isConstantIndex)
        }
    }

    // MARK: Swizzles and indexing

    static func swizzleLetters(_ indices: [Int]) -> String {
        String(indices.map { Array("xyzw")[$0] })
    }

    func swizzle(_ v: GLValue, _ indices: [Int]) -> GLValue {
        let type = indices.count == 1 ? v.type.elementType! : v.type.with(components: indices.count)!
        return GLValue(code: "\(v.code).\(Self.swizzleLetters(indices))", type: type)
    }

    private func emitAttribute(_ a: Attribute) throws -> GLValue {
        let base = try emitExpression(a.value)
        if case .structure(let name, let members) = base.type {
            guard let k = members.firstIndex(where: { $0.0 == a.attr }) else {
                throw PyShaderError("`\(name)` has no field `\(a.attr)`", line: a.lineno)
            }
            return GLValue(code: "\(base.code).\(compiler.member(base.type, k))", type: members[k].1)
        }
        guard base.type.isVector else {
            throw PyShaderError("`\(base.type)` has no attribute `\(a.attr)`", line: a.lineno)
        }
        guard let indices = Swizzle.indices(for: a.attr) else {
            throw PyShaderError("`\(a.attr)` is not a vector component", line: a.lineno)
        }
        if let bad = indices.first(where: { $0 >= base.type.componentCount }) {
            throw PyShaderError("component \(bad) is out of range for `\(base.type)`", line: a.lineno)
        }
        return swizzle(base, indices)
    }

    private func emitSubscript(_ s: Subscript) throws -> GLValue {
        let base = try emitExpression(s.value)
        switch base.type {
        case .vector:
            if let k = constantIndex(s.slice) {
                let i = k < 0 ? k + base.type.componentCount : k
                guard (0..<base.type.componentCount).contains(i) else {
                    throw PyShaderError("index \(k) is out of range for `\(base.type)`", line: s.lineno)
                }
                return swizzle(base, [i])
            }
            let index = try emitIndex(s.slice, count: base.type.componentCount, line: s.lineno)
            return GLValue(code: "\(base.code)[\(index)]", type: base.type.elementType!)
        case .tuple:
            guard let k = constantIndex(s.slice) else {
                throw PyShaderError("tuple index must be a constant", line: s.lineno)
            }
            let i = k < 0 ? k + base.type.count : k
            guard let member = base.type.elementType(at: i) else {
                throw PyShaderError("index \(k) is out of range for `\(base.type)`", line: s.lineno)
            }
            return GLValue(code: "\(base.code).m\(i)", type: member)
        case .matrix, .array:
            let element = base.type.elementType(at: nil)!
            let index = try emitIndex(s.slice, count: base.type.count, line: s.lineno)
            // An array is always a variable here; a matrix value is indexed in place.
            return GLValue(code: "\(base.code)[\(index)]", type: element)
        default:
            throw PyShaderError("`\(base.type)` cannot be indexed", line: s.lineno)
        }
    }

    /// An index as GLSL ES 1.00 takes one: a constant, or an expression of
    /// constants and `for` counters (Appendix A).
    func emitIndex(_ e: Expression, count: Int, line: Int) throws -> String {
        if let k = constantIndex(e) {
            let i = k < 0 ? k + count : k
            guard (0..<count).contains(i) else {
                throw PyShaderError("index \(k) is out of range for a \(count)-element value", line: line)
            }
            return "\(i)"
        }
        if case .slice = e {
            throw PyShaderError("slicing is not supported; use swizzles (`v.xy`)", line: line)
        }
        let v = try emitExpression(e)
        guard v.type.isScalar, v.type.isInt else {
            throw PyShaderError("index must be an integer, got `\(v.type)`", line: line)
        }
        if case .int(let k) = v.literal {
            let i = k < 0 ? k + count : k
            guard (0..<count).contains(i) else {
                throw PyShaderError("index \(k) is out of range for a \(count)-element value", line: line)
            }
            return "\(i)"
        }
        guard v.isConstantIndex else {
            throw PyShaderError("OpenGL ES 2 indexes only with constants and `for` counters (GLSL ES 1.00, Appendix A); this index is computed at run time", line: line)
        }
        return v.code
    }

    // MARK: Calls

    private func emitCall(_ c: Call) throws -> GLValue {
        if case .name(let n) = c.fun, let type = program.structs[n.id] {
            return try constructStruct(type, c, line: c.lineno)
        }
        guard c.keywords.isEmpty else {
            throw PyShaderError("keyword arguments are not supported in shader calls", line: c.lineno)
        }
        if case .lambda(let l) = c.fun {
            let args = try c.args.map { try emitExpression($0) }
            return try compiler.callLambda(LambdaTemplate(name: "<lambda>", lambda: l, line: l.lineno), args: args, from: self, line: c.lineno)
        }
        let name: String
        switch c.fun {
        case .name(let n): name = n.id
        case .attribute(let a):
            if case .name(let m) = a.value, ShaderProgram.isShaderModule(m.id) {
                name = a.attr
            } else {
                throw PyShaderError("methods are not supported; call `\(a.attr)(...)` as a function", line: c.lineno)
            }
        default:
            throw PyShaderError("unsupported call target", line: c.lineno)
        }
        let args = try c.args.map { try emitExpression($0) }
        if let type = ShaderType.named(name) {
            return try construct(type, args, line: c.lineno)
        }
        if let fn = program.functions[name] {
            return try callUser(fn, args, line: c.lineno)
        }
        if let lambda = program.lambdas[name] {
            return try compiler.callLambda(lambda, args: args, from: self, line: c.lineno)
        }
        if let texture = compiler.texture(named: name) {
            guard args.count == 1 else {
                throw PyShaderError("`\(name)` is a texture: sample it with one `float2`, got \(args.count) argument(s)", line: c.lineno)
            }
            let p = try coerce(args[0], to: .float(2), line: c.lineno)
            return try compiler.sampleTexture(texture, at: p, from: self, line: c.lineno)
        }
        if let v = try callBuiltin(name, args, line: c.lineno) {
            return v
        }
        if program.globals[name] != nil || program.variables[name] != nil {
            throw PyShaderError("`\(name)` is a \(program.globals[name] != nil ? "constant" : "variable"), not a function", line: c.lineno)
        }
        throw PyShaderError("unknown function `\(name)`", line: c.lineno)
    }

    private func constructStruct(_ type: ShaderType, _ c: Call, line: Int) throws -> GLValue {
        guard case .structure(let name, let members) = type else { preconditionFailure() }
        var values: [GLValue?] = Array(repeating: nil, count: members.count)
        guard c.args.count <= members.count else {
            throw PyShaderError("`\(name)` has \(members.count) field(s), got \(c.args.count) positional argument(s)", line: line)
        }
        for (i, arg) in c.args.enumerated() {
            values[i] = try coerce(try emitExpression(arg), to: members[i].1, line: line)
        }
        for keyword in c.keywords {
            guard let field = keyword.arg, let k = members.firstIndex(where: { $0.0 == field }) else {
                throw PyShaderError("`\(name)` has no field `\(keyword.arg ?? "**")`", line: line)
            }
            guard values[k] == nil else {
                throw PyShaderError("`\(name)`: field `\(field)` given twice", line: line)
            }
            values[k] = try coerce(try emitExpression(keyword.value), to: members[k].1, line: line)
        }
        if let missing = members.indices.first(where: { values[$0] == nil }) {
            throw PyShaderError("`\(name)`: missing field `\(members[missing].0)`", line: line)
        }
        return GLValue(code: "\(try typeName(type, line: line))(\(values.map { $0!.code }.joined(separator: ", ")))", type: type)
    }

    private func callUser(_ fn: ShaderFunctionSignature, _ args: [GLValue], line: Int) throws -> GLValue {
        guard fn.name != functionName else {
            throw PyShaderError("recursion is not allowed in shader code (`\(fn.name)` calls itself)", line: line)
        }
        guard !program.isEntry(fn.name) else {
            throw PyShaderError("`\(fn.name)` is the entry point and cannot be called", line: line)
        }
        guard args.count == fn.params.count else {
            throw PyShaderError("`\(fn.name)` takes \(fn.params.count) argument(s), got \(args.count)", line: line)
        }
        var params = fn.params
        if fn.isGeneric {
            params = try zip(args, fn.params).map { arg, param in
                guard let bound = ShaderProgram.bind(param.type, to: arg.type) else {
                    throw PyShaderError("`\(fn.name)` parameter `\(param.name)` takes a `\(param.type)`, got `\(arg.type)`", line: line)
                }
                return (param.name, bound)
            }
        }
        var codes: [String] = []
        for (arg, param) in zip(args, params) {
            if case .sampledImage = param.type { continue }
            codes.append(try coerce(arg, to: param.type, line: line).code)
        }
        compiler.recordCall(from: functionName, to: fn.name)
        let target = fn.isGeneric ? try compiler.instantiate(fn, params: params) : compiler.functionName(fn.name)!
        uses.insert("fn:" + target)
        return GLValue(code: "\(target)(\(codes.joined(separator: ", ")))", type: fn.returnType)
    }

    /// `float4(1, 0, 0, 1)`, `float3(v2, z)`, `float4(0.5)`, `int(x)`: GLSL's constructors.
    func construct(_ type: ShaderType, _ args: [GLValue], line: Int) throws -> GLValue {
        if type.isMatrix { return try constructMatrix(type, args, line: line) }
        let n = type.componentCount
        let element = type.elementType!
        let name = try typeName(type, line: line)
        if args.isEmpty {
            let zero: GLLiteral = element.isBool ? .bool(false) : element.isFloat ? .float(0) : .int(0)
            let z = Self.literal(zero, type: element)
            return type.isScalar ? z : GLValue(code: "\(name)(\(z.code))", type: type)
        }
        if type.isScalar {
            guard args.count == 1 else {
                throw PyShaderError("`\(type)()` takes exactly one argument", line: line)
            }
            if args[0].type.isVector {
                throw PyShaderError("cannot convert `\(args[0].type)` to `\(type)`; pick a component first", line: line)
            }
            return try convert(args[0], to: type, line: line)
        }
        if args.count == 1 {
            let a = args[0]
            if a.type.isScalar {
                let s = try convert(a, to: element, line: line)
                return GLValue(code: "\(name)(\(s.code))", type: type)
            }
            if a.type.componentCount == n {
                return try convert(a, to: type, line: line)
            }
            if a.type.componentCount > n {
                guard a.type.isVector else {
                    throw PyShaderError("`\(type)` needs \(n) components, `\(a.type)` has \(a.type.componentCount)", line: line)
                }
                return GLValue(code: "\(name)(\(a.code))", type: type)
            }
            throw PyShaderError("`\(type)` needs \(n) components, `\(a.type)` has \(a.type.componentCount)", line: line)
        }
        var count = 0
        var parts: [String] = []
        for a in args {
            guard a.type.isScalar || a.type.isVector else {
                throw PyShaderError("cannot convert `\(a.type)` to `\(element)`", line: line)
            }
            count += a.type.componentCount
            parts.append(try convert(a, to: a.type.withKind(element.scalarKind!), line: line).code)
        }
        guard count == n else {
            throw PyShaderError("`\(type)` needs \(n) components, got \(count)", line: line)
        }
        return GLValue(code: "\(name)(\(parts.joined(separator: ", ")))", type: type)
    }
}
