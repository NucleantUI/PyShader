//
//  ExpressionEmitter.swift
//  PyShader
//
//  Expression lowering. Python numeric semantics are kept where they are
//  cheap and unsurprising on a GPU: `/` is always float division, `//`
//  floors, `%` takes the sign of the divisor, ints promote to floats.
//

import PySwiftAST

extension FunctionEmitter {

    func emitExpression(_ expr: Expression) throws -> Value {
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
            return try emitBoolOp(b)

        case .compare(let c):
            return try emitCompare(c)

        case .attribute(let a):
            return try emitAttribute(a)

        case .subscriptExpr(let s):
            return try emitSubscript(s)

        case .call(let c):
            return try emitCall(c)

        case .ifExp(let i):
            return try emitIfExp(i)

        case .lambda(let l):
            throw PyShaderError("lambdas must be bound to a module-level name before use", line: l.lineno)
        case .tuple(let t):
            return try emitTupleLiteral(t.elts, line: t.lineno)
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

    private func emitConstant(_ c: Constant) throws -> Value {
        switch c.value {
        case .int(let v):
            return Value(id: builder.constant(int: v), type: .int)
        case .float(let v):
            return Value(id: builder.constant(float: v), type: .float)
        case .bool(let v):
            return Value(id: builder.constant(bool: v), type: .bool)
        case .none:
            throw PyShaderError("`None` is not a value in shader code", line: c.lineno)
        case .string, .bytes:
            throw PyShaderError("strings are not available in shader code", line: c.lineno)
        case .complex:
            throw PyShaderError("complex numbers are not available in shader code", line: c.lineno)
        case .ellipsis:
            throw PyShaderError("`...` is not a value", line: c.lineno)
        }
    }

    private func emitName(_ n: Name) throws -> Value {
        if let local = lookupLocal(n.id) {
            return load(local.ptr, type: local.type)
        }
        if let handle = lookupHandle(n.id) {
            return Value(id: 0, type: handle)
        }
        if let global = program.globals[n.id] {
            return try compiler.withGlobalInlining(n.id, line: n.lineno) {
                try emitExpression(global.expr)
            }
        }
        if program.lambdas[n.id] != nil || program.functions[n.id] != nil {
            throw PyShaderError("`\(n.id)` is a function; call it", line: n.lineno)
        }
        if ShaderType.named(n.id) != nil || program.structs[n.id] != nil {
            throw PyShaderError("`\(n.id)` is a type; call it to construct a value", line: n.lineno)
        }
        throw PyShaderError("`\(n.id)` is not defined", line: n.lineno)
    }

    // MARK: Composite literals

    /// `(a, b)` -> a tuple value (a struct); mostly reached through `return a, b`.
    private func emitTupleLiteral(_ elts: [Expression], line: Int) throws -> Value {
        guard !elts.isEmpty else { throw PyShaderError("empty tuple", line: line) }
        let values = try elts.map { try emitExpression($0) }
        for v in values where !v.type.isStorable {
            throw PyShaderError("cannot put a `\(v.type)` in a tuple", line: line)
        }
        let type = ShaderType.tuple(values.map(\.type))
        return emit(.opCompositeConstruct, type: type, values.map(\.id))
    }

    /// `[a, b, c]` -> a fixed-size array; every element converts to the first one's type.
    private func emitListLiteral(_ elts: [Expression], line: Int) throws -> Value {
        guard !elts.isEmpty else { throw PyShaderError("a list needs at least one element to fix its type", line: line) }
        let values = try elts.map { try emitExpression($0) }
        let elem = values[0].type
        guard elem.isStorable else { throw PyShaderError("cannot put a `\(elem)` in a list", line: line) }
        let ids = try values.map { try coerce($0, to: elem, line: line).id }
        let type = ShaderType.array(elem, ids.count)
        if ids.allSatisfy(isLiteral) {
            return Value(id: builder.constantComposite(type: type, elements: ids), type: type)
        }
        return emit(.opCompositeConstruct, type: type, ids)
    }

    /// `[x] * n` / `n * [x]`: Python's repeat idiom for a fixed-size array.
    private func repeatedList(_ b: BinOp) throws -> Value? {
        guard b.op == .mult else { return nil }
        let (listExpr, countExpr): (Expression, Expression)
        if case .list = b.left { (listExpr, countExpr) = (b.left, b.right) }
        else if case .list = b.right { (listExpr, countExpr) = (b.right, b.left) }
        else { return nil }
        guard let n = constantIndex(countExpr), n > 0 else {
            throw PyShaderError("list repeat count must be a positive constant", line: b.lineno)
        }
        let base = try emitExpression(listExpr)
        guard case .array(let elem, let m) = base.type else { return nil }
        var ids: [SpirvId] = []
        for _ in 0..<n {
            for i in 0..<m { ids.append(emit(.opCompositeExtract, type: elem, [base.id, UInt32(i)]).id) }
        }
        return emit(.opCompositeConstruct, type: .array(elem, n * m), ids)
    }

    /// Converts an array value to an array type with the same length and a different element type.
    func coerceArray(_ v: Value, to target: ShaderType, line: Int) throws -> Value {
        guard case .array(let from, let n) = v.type, case .array(let to, let m) = target, n == m else {
            throw PyShaderError("cannot convert `\(v.type)` to `\(target)`", line: line)
        }
        var ids: [SpirvId] = []
        for i in 0..<n {
            let e = emit(.opCompositeExtract, type: from, [v.id, UInt32(i)])
            ids.append(try coerce(e, to: to, line: line).id)
        }
        return emit(.opCompositeConstruct, type: target, ids)
    }

    // MARK: Unary / boolean

    private func emitUnary(_ u: UnaryOp) throws -> Value {
        let v = try emitExpression(u.operand)
        switch u.op {
        case .uAdd:
            guard v.type.isNumeric else { throw PyShaderError("unary + needs a number", line: u.lineno) }
            return v
        case .uSub:
            guard v.type.isNumeric else { throw PyShaderError("unary - needs a number", line: u.lineno) }
            if let literal = builder.literalInt(v.id) {
                return Value(id: builder.constant(int: -literal, type: v.type), type: v.type)
            }
            if let literal = builder.literalFloat(v.id) {
                return Value(id: builder.constant(float: -literal, type: v.type), type: v.type)
            }
            return emit(v.type.isFloat ? .opFNegate : .opSNegate, type: v.type, [v.id])
        case .not:
            let b = try truthy(v, line: u.lineno)
            return emit(.opLogicalNot, type: .bool, [b.id])
        case .invert:
            guard v.type.isInt else { throw PyShaderError("~ needs an integer", line: u.lineno) }
            return emit(.opNot, type: v.type, [v.id])
        }
    }

    private func emitBoolOp(_ b: BoolOp) throws -> Value {
        let op: SpirvOp = b.op == .and ? .opLogicalAnd : .opLogicalOr
        var acc = try truthy(try emitExpression(b.values[0]), line: b.lineno)
        for e in b.values.dropFirst() {
            let next = try truthy(try emitExpression(e), line: b.lineno)
            acc = emit(op, type: .bool, [acc.id, next.id])
        }
        return acc
    }

    /// Python truthiness restricted to what makes sense on a GPU: bools pass through, numbers compare to zero.
    func truthy(_ v: Value, line: Int) throws -> Value {
        if v.type == .bool { return v }
        guard v.type.isScalar, v.type.isNumeric else {
            throw PyShaderError("condition must be a scalar bool or number, got `\(v.type)` (use any()/all() for vectors)", line: line)
        }
        let zero = builder.zero(of: v.type)
        return emit(v.type.isFloat ? .opFUnordNotEqual : .opINotEqual, type: .bool, [v.id, zero])
    }

    // MARK: Comparisons

    private func emitCompare(_ c: Compare) throws -> Value {
        var left = try emitExpression(c.left)
        var result: Value?
        for (op, rightExpr) in zip(c.ops, c.comparators) {
            let right = try emitExpression(rightExpr)
            let cmp = try compare(op, left, right, line: c.lineno)
            if let prev = result {
                guard prev.type == .bool, cmp.type == .bool else {
                    throw PyShaderError("chained comparisons only work on scalars", line: c.lineno)
                }
                result = emit(.opLogicalAnd, type: .bool, [prev.id, cmp.id])
            } else {
                result = cmp
            }
            left = right
        }
        return result!
    }

    func compare(_ op: CmpOp, _ l: Value, _ r: Value, line: Int) throws -> Value {
        let (a, b) = try promote(l, r, line: line)
        let kind = a.type.scalarKind!
        let resultType = ShaderType.bool(a.type.componentCount)
        let spirvOp: SpirvOp
        switch (op, kind) {
        case (.eq, .bool): spirvOp = .opLogicalEqual
        case (.notEq, .bool): spirvOp = .opLogicalNotEqual
        case (.eq, .float): spirvOp = .opFOrdEqual
        case (.notEq, .float): spirvOp = .opFUnordNotEqual
        case (.lt, .float): spirvOp = .opFOrdLessThan
        case (.ltE, .float): spirvOp = .opFOrdLessThanEqual
        case (.gt, .float): spirvOp = .opFOrdGreaterThan
        case (.gtE, .float): spirvOp = .opFOrdGreaterThanEqual
        case (.eq, .int): spirvOp = .opIEqual
        case (.notEq, .int): spirvOp = .opINotEqual
        case (.lt, .int(_, let s)): spirvOp = s ? .opSLessThan : .opULessThan
        case (.ltE, .int(_, let s)): spirvOp = s ? .opSLessThanEqual : .opULessThanEqual
        case (.gt, .int(_, let s)): spirvOp = s ? .opSGreaterThan : .opUGreaterThan
        case (.gtE, .int(_, let s)): spirvOp = s ? .opSGreaterThanEqual : .opUGreaterThanEqual
        case (.is, _), (.isNot, _):
            throw PyShaderError("`is` is not meaningful in shader code; use == / !=", line: line)
        case (.in, _), (.notIn, _):
            throw PyShaderError("`in` is not available in shader code", line: line)
        default:
            throw PyShaderError("cannot order `\(a.type)` values", line: line)
        }
        return emit(spirvOp, type: resultType, [a.id, b.id])
    }

    // MARK: Arithmetic

    func binary(_ op: Operator, _ l: Value, _ r: Value, line: Int) throws -> Value {
        if l.type.isMatrix || r.type.isMatrix {
            return try matrixBinary(op, l, r, line: line)
        }
        if op == .matMult {
            // `a @ b` on vectors is the dot product.
            let (a, b) = try promote(l, r, line: line, forceFloat: true)
            guard a.type.isVector else { throw PyShaderError("`@` needs vectors or matrices", line: line) }
            return emit(.opDot, type: a.type.elementType!, [a.id, b.id])
        }
        // Bitwise ops on bools are logical ops.
        if l.type.isBool && r.type.isBool {
            switch op {
            case .bitAnd: return try logical(.opLogicalAnd, l, r, line: line)
            case .bitOr: return try logical(.opLogicalOr, l, r, line: line)
            case .bitXor: return try logical(.opLogicalNotEqual, l, r, line: line)
            default: break
            }
        }
        guard l.type.isNumeric, r.type.isNumeric else {
            throw PyShaderError("cannot apply `\(symbol(op))` to `\(l.type)` and `\(r.type)`", line: line)
        }

        switch op {
        case .mult:
            // float vector * scalar is a dedicated instruction.
            if let (vec, scalar) = vectorTimesScalarOperands(l, r) {
                let s = try coerce(scalar, to: vec.type.elementType!, line: line)
                return emit(.opVectorTimesScalar, type: vec.type, [vec.id, s.id])
            }
            let (a, b) = try promote(l, r, line: line)
            return emit(a.type.isFloat ? .opFMul : .opIMul, type: a.type, [a.id, b.id])

        case .add:
            let (a, b) = try promote(l, r, line: line)
            return emit(a.type.isFloat ? .opFAdd : .opIAdd, type: a.type, [a.id, b.id])

        case .sub:
            let (a, b) = try promote(l, r, line: line)
            return emit(a.type.isFloat ? .opFSub : .opISub, type: a.type, [a.id, b.id])

        case .div:
            // Python true division: ints become floats.
            let (a, b) = try promote(l, r, line: line, forceFloat: true)
            return emit(.opFDiv, type: a.type, [a.id, b.id])

        case .floorDiv:
            let (a, b) = try promote(l, r, line: line)
            if a.type.isFloat {
                let q = emit(.opFDiv, type: a.type, [a.id, b.id])
                return emitExt(.floor, type: a.type, [q.id])
            }
            if !a.type.scalarKind!.isSigned {
                return emit(.opUDiv, type: a.type, [a.id, b.id])
            }
            // floor(a / b) == (a - (a mod b)) / b with a floored (sign-of-divisor) mod.
            let m = emit(.opSMod, type: a.type, [a.id, b.id])
            let exact = emit(.opISub, type: a.type, [a.id, m.id])
            return emit(.opSDiv, type: a.type, [exact.id, b.id])

        case .mod:
            let (a, b) = try promote(l, r, line: line)
            if a.type.isFloat { return emit(.opFMod, type: a.type, [a.id, b.id]) }
            return emit(a.type.scalarKind!.isSigned ? .opSMod : .opUMod, type: a.type, [a.id, b.id])

        case .pow:
            let (a, b) = try promote(l, r, line: line, forceFloat: true)
            return emitExt(.pow, type: a.type, [a.id, b.id])

        case .bitAnd, .bitOr, .bitXor, .lShift, .rShift:
            guard l.type.isInt, r.type.isInt else {
                throw PyShaderError("`\(symbol(op))` needs integer operands", line: line)
            }
            let (a, b) = try promote(l, r, line: line)
            let spirvOp: SpirvOp
            switch op {
            case .bitAnd: spirvOp = .opBitwiseAnd
            case .bitOr: spirvOp = .opBitwiseOr
            case .bitXor: spirvOp = .opBitwiseXor
            case .lShift: spirvOp = .opShiftLeftLogical
            default: spirvOp = a.type.scalarKind!.isSigned ? .opShiftRightArithmetic : .opShiftRightLogical
            }
            return emit(spirvOp, type: a.type, [a.id, b.id])

        case .matMult:
            throw PyShaderError("`@` needs vectors or matrices", line: line)
        }
    }

    // MARK: Matrices

    /// `*` and `@` with a matrix operand are linear-algebra products, as in Metal and GLSL;
    /// `+`, `-` and `/ scalar` work column by column.
    private func matrixBinary(_ op: Operator, _ l: Value, _ r: Value, line: Int) throws -> Value {
        switch op {
        case .mult, .matMult:
            switch (l.type, r.type) {
            case (.matrix(let k, let lc, let lr), .matrix(_, let rc, let rr)):
                guard lc == rr else { throw PyShaderError("cannot multiply `\(l.type)` by `\(r.type)`", line: line) }
                let rm = try coerceMatrix(r, kind: k, line: line)
                return emit(.opMatrixTimesMatrix, type: .matrix(k, columns: rc, rows: lr), [l.id, rm.id])
            case (.matrix(let k, let cols, let rows), .vector):
                let v = try coerce(r, to: .vector(k, cols), line: line)
                return emit(.opMatrixTimesVector, type: .vector(k, rows), [l.id, v.id])
            case (.vector, .matrix(let k, let cols, let rows)):
                let v = try coerce(l, to: .vector(k, rows), line: line)
                return emit(.opVectorTimesMatrix, type: .vector(k, cols), [v.id, r.id])
            case (.matrix(let k, _, _), .scalar):
                let s = try coerce(r, to: .scalar(k), line: line)
                return emit(.opMatrixTimesScalar, type: l.type, [l.id, s.id])
            case (.scalar, .matrix(let k, _, _)):
                let s = try coerce(l, to: .scalar(k), line: line)
                return emit(.opMatrixTimesScalar, type: r.type, [r.id, s.id])
            default:
                throw PyShaderError("cannot multiply `\(l.type)` by `\(r.type)`", line: line)
            }
        case .add, .sub:
            guard case .matrix(let k, let cols, let rows) = l.type, l.type == r.type else {
                throw PyShaderError("cannot apply `\(symbol(op))` to `\(l.type)` and `\(r.type)`", line: line)
            }
            let column = ShaderType.vector(k, rows)
            var ids: [SpirvId] = []
            for c in 0..<cols {
                let a = emit(.opCompositeExtract, type: column, [l.id, UInt32(c)])
                let b = emit(.opCompositeExtract, type: column, [r.id, UInt32(c)])
                ids.append(emit(op == .add ? .opFAdd : .opFSub, type: column, [a.id, b.id]).id)
            }
            return emit(.opCompositeConstruct, type: l.type, ids)
        case .div:
            guard case .matrix(let k, _, _) = l.type, r.type.isScalar, r.type.isNumeric else {
                throw PyShaderError("a matrix can only be divided by a scalar", line: line)
            }
            let s = try coerce(r, to: .scalar(k), line: line)
            let inverse = emit(.opFDiv, type: .scalar(k), [builder.constant(float: 1, type: .scalar(k)), s.id])
            return emit(.opMatrixTimesScalar, type: l.type, [l.id, inverse.id])
        default:
            throw PyShaderError("cannot apply `\(symbol(op))` to matrices", line: line)
        }
    }

    private func coerceMatrix(_ v: Value, kind: ScalarKind, line: Int) throws -> Value {
        guard case .matrix(let k, _, _) = v.type else { throw PyShaderError("expected a matrix", line: line) }
        guard k == kind else { throw PyShaderError("cannot mix `\(k.name)` and `\(kind.name)` matrices", line: line) }
        return v
    }

    /// `float3x3(c0, c1, c2)` (columns), 9 scalars column-major, `float3x3(s)` (diagonal),
    /// `float3x3(m)` (resize, identity-filled), `float3x3()` (identity).
    private func constructMatrix(_ type: ShaderType, _ args: [Value], line: Int) throws -> Value {
        guard case .matrix(let k, let cols, let rows) = type else { preconditionFailure() }
        let column = ShaderType.vector(k, rows)
        let elem = ShaderType.scalar(k)
        func diagonal(_ s: SpirvId) -> Value {
            let zero = builder.constant(float: 0, type: elem)
            var columns: [SpirvId] = []
            for c in 0..<cols {
                let comps = (0..<rows).map { $0 == c ? s : zero }
                columns.append(builder.literalFloat(s) != nil
                    ? builder.constantComposite(type: column, elements: comps)
                    : emit(.opCompositeConstruct, type: column, comps).id)
            }
            return builder.literalFloat(s) != nil
                ? Value(id: builder.constantComposite(type: type, elements: columns), type: type)
                : emit(.opCompositeConstruct, type: type, columns)
        }
        if args.isEmpty {
            return diagonal(builder.constant(float: 1, type: elem))
        }
        if args.count == 1, args[0].type.isScalar {
            return diagonal(try convert(args[0], to: elem, line: line).id)
        }
        if args.count == 1, case .matrix(let mk, let mc, let mr) = args[0].type {
            guard mk == k else { throw PyShaderError("cannot convert `\(args[0].type)` to `\(type)`", line: line) }
            let identity = diagonal(builder.constant(float: 1, type: elem))
            var columns: [SpirvId] = []
            for c in 0..<cols {
                if c < mc {
                    let src = emit(.opCompositeExtract, type: .vector(mk, mr), [args[0].id, UInt32(c)])
                    var comps: [SpirvId] = []
                    for r in 0..<rows {
                        if r < mr {
                            comps.append(emit(.opCompositeExtract, type: elem, [src.id, UInt32(r)]).id)
                        } else {
                            comps.append(builder.constant(float: r == c ? 1 : 0, type: elem))
                        }
                    }
                    columns.append(emit(.opCompositeConstruct, type: column, comps).id)
                } else {
                    columns.append(emit(.opCompositeExtract, type: column, [identity.id, UInt32(c)]).id)
                }
            }
            return emit(.opCompositeConstruct, type: type, columns)
        }
        if args.count == cols, args.allSatisfy({ $0.type.isVector }) {
            let columns = try args.map { try coerce($0, to: column, line: line).id }
            if columns.allSatisfy(isLiteral) {
                return Value(id: builder.constantComposite(type: type, elements: columns), type: type)
            }
            return emit(.opCompositeConstruct, type: type, columns)
        }
        // Scalars (and vectors) flattened column-major.
        var components: [SpirvId] = []
        for a in args {
            let converted = try convert(a, to: a.type.withKind(k), line: line)
            if converted.type.isScalar {
                components.append(converted.id)
            } else if converted.type.isVector {
                for i in 0..<converted.type.componentCount { components.append(swizzle(converted, [i]).id) }
            } else {
                throw PyShaderError("cannot build `\(type)` from `\(a.type)`", line: line)
            }
        }
        guard components.count == cols * rows else {
            throw PyShaderError("`\(type)` needs \(cols * rows) components, got \(components.count)", line: line)
        }
        var columns: [SpirvId] = []
        for c in 0..<cols {
            let comps = Array(components[(c * rows)..<((c + 1) * rows)])
            columns.append(comps.allSatisfy(isLiteral)
                ? builder.constantComposite(type: column, elements: comps)
                : emit(.opCompositeConstruct, type: column, comps).id)
        }
        if columns.allSatisfy(isLiteral) {
            return Value(id: builder.constantComposite(type: type, elements: columns), type: type)
        }
        return emit(.opCompositeConstruct, type: type, columns)
    }

    /// `(vector, scalar)` when the product can use OpVectorTimesScalar without changing the vector's type.
    private func vectorTimesScalarOperands(_ l: Value, _ r: Value) -> (Value, Value)? {
        func fits(_ vec: Value, _ s: Value) -> Bool {
            vec.type.isVector && vec.type.isFloat && s.type.isScalar && (s.type.isInt || s.type.scalarKind == vec.type.scalarKind)
        }
        if fits(l, r) { return (l, r) }
        if fits(r, l) { return (r, l) }
        return nil
    }

    private func logical(_ op: SpirvOp, _ l: Value, _ r: Value, line: Int) throws -> Value {
        let (a, b) = try promote(l, r, line: line)
        return emit(op, type: a.type, [a.id, b.id])
    }

    private func symbol(_ op: Operator) -> String {
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

    // MARK: Type promotion / coercion

    /// Brings two operands to a common type: ints promote to floats, narrower to wider,
    /// scalars broadcast to vectors. Vectors of different sizes never unify.
    func promote(_ l: Value, _ r: Value, line: Int, forceFloat: Bool = false) throws -> (Value, Value) {
        guard let lk = l.type.scalarKind, let rk = r.type.scalarKind else {
            throw PyShaderError("cannot combine `\(l.type)` and `\(r.type)`", line: line)
        }
        // An int literal takes on the other operand's integer type (`u * 12345` with `u: uint`).
        let l = retypeLiteral(l, toMatch: rk)
        let r = retypeLiteral(r, toMatch: lk)
        var kind = try unify(l.type.scalarKind!, r.type.scalarKind!, line: line)
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

    private func retypeLiteral(_ v: Value, toMatch kind: ScalarKind) -> Value {
        guard case .int = kind, v.type.isScalar, v.type.scalarKind != kind,
              let literal = builder.literalInt(v.id) else { return v }
        let t = ShaderType.scalar(kind)
        return Value(id: builder.constant(int: literal, type: t), type: t)
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

    /// Implicit conversion. Allowed: int -> float, narrow -> wide, scalar -> vector (splat).
    /// Not allowed: float -> int, bool <-> number, vector -> scalar, vectorN -> vectorM.
    func coerce(_ v: Value, to target: ShaderType, line: Int) throws -> Value {
        if v.type == target { return v }
        if case .tuple(let from) = v.type, case .tuple(let to) = target, from.count == to.count {
            var ids: [SpirvId] = []
            for (i, (f, t)) in zip(from, to).enumerated() {
                let member = emit(.opCompositeExtract, type: f, [v.id, UInt32(i)])
                ids.append(try coerce(member, to: t, line: line).id)
            }
            return emit(.opCompositeConstruct, type: target, ids)
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
            if isLiteral(scalar.id) {
                return Value(id: builder.constantComposite(type: target, elements: Array(repeating: scalar.id, count: toN)), type: target)
            }
            return emit(.opCompositeConstruct, type: target, Array(repeating: scalar.id, count: toN))
        }
        switch (fromKind, toKind) {
        case (.int(_, let signed), .float):
            if let literal = builder.literalInt(v.id) {
                return Value(id: builder.constant(float: Double(literal), type: target), type: target)
            }
            return emit(signed ? .opConvertSToF : .opConvertUToF, type: target, [v.id])
        case (.float, .float):
            if let literal = builder.literalFloat(v.id) {
                return Value(id: builder.constant(float: literal, type: target), type: target)
            }
            return emit(.opFConvert, type: target, [v.id])
        case (.int(let fb, let fs), .int(let tb, let ts)):
            guard fs == ts else {
                throw PyShaderError("cannot implicitly convert `\(v.type)` to `\(target)`; use \(target)(...)", line: line)
            }
            guard tb >= fb else {
                throw PyShaderError("cannot implicitly narrow `\(v.type)` to `\(target)`; use \(target)(...)", line: line)
            }
            return emit(fs ? .opSConvert : .opUConvert, type: target, [v.id])
        case (.float, .int):
            throw PyShaderError("cannot implicitly convert `\(v.type)` to `\(target)`; use \(target)(...)", line: line)
        default:
            throw PyShaderError("cannot convert `\(v.type)` to `\(target)`", line: line)
        }
    }

    /// Explicit conversion as done by `float(x)`, `int(x)`, `bool(x)`, `half(x)`, ...
    func convert(_ v: Value, to target: ShaderType, line: Int) throws -> Value {
        if v.type == target { return v }
        guard let fromKind = v.type.scalarKind, let toKind = target.scalarKind else {
            throw PyShaderError("cannot convert `\(v.type)` to `\(target)`", line: line)
        }
        guard v.type.componentCount == target.componentCount else {
            if v.type.isScalar {
                let s = try convert(v, to: .scalar(toKind), line: line)
                return emit(.opCompositeConstruct, type: target, Array(repeating: s.id, count: target.componentCount))
            }
            throw PyShaderError("cannot convert `\(v.type)` to `\(target)`", line: line)
        }
        switch (fromKind, toKind) {
        case (_, .bool):
            let zero = builder.zero(of: v.type)
            return emit(v.type.isFloat ? .opFUnordNotEqual : .opINotEqual, type: target, [v.id, zero])
        case (.bool, .float):
            let t = splatConstant(target, float: 1)
            let f = splatConstant(target, float: 0)
            return emit(.opSelect, type: target, [v.id, t, f])
        case (.bool, .int):
            let t = splatConstant(target, int: 1)
            let f = splatConstant(target, int: 0)
            return emit(.opSelect, type: target, [v.id, t, f])
        case (.float, .int(_, let signed)):
            return emit(signed ? .opConvertFToS : .opConvertFToU, type: target, [v.id])
        case (.int(_, let signed), .float):
            if let literal = builder.literalInt(v.id) {
                return Value(id: builder.constant(float: Double(literal), type: target), type: target)
            }
            return emit(signed ? .opConvertSToF : .opConvertUToF, type: target, [v.id])
        case (.float, .float):
            if let literal = builder.literalFloat(v.id) {
                return Value(id: builder.constant(float: literal, type: target), type: target)
            }
            return emit(.opFConvert, type: target, [v.id])
        case (.int(let fb, _), .int(let tb, let ts)):
            if fb == tb {
                return emit(.opBitcast, type: target, [v.id])
            }
            return emit(ts ? .opSConvert : .opUConvert, type: target, [v.id])
        }
    }

    private func isLiteral(_ id: SpirvId) -> Bool {
        builder.literalInt(id) != nil || builder.literalFloat(id) != nil
    }

    func splatConstant(_ type: ShaderType, float: Double) -> SpirvId {
        let elem = type.elementType!
        let s = builder.constant(float: float, type: elem)
        if type.isScalar { return s }
        return builder.constantComposite(type: type, elements: Array(repeating: s, count: type.componentCount))
    }

    func splatConstant(_ type: ShaderType, int: Int) -> SpirvId {
        let elem = type.elementType!
        let s = builder.constant(int: int, type: elem)
        if type.isScalar { return s }
        return builder.constantComposite(type: type, elements: Array(repeating: s, count: type.componentCount))
    }

    // MARK: Swizzles and indexing

    /// Reads components out of a vector value: one index -> scalar, several -> vector.
    func swizzle(_ v: Value, _ indices: [Int]) -> Value {
        if indices.count == 1 {
            return emit(.opCompositeExtract, type: v.type.elementType!, [v.id, UInt32(indices[0])])
        }
        let type = v.type.with(components: indices.count)!
        return emit(.opVectorShuffle, type: type, [v.id, v.id] + indices.map { UInt32($0) })
    }

    private func emitAttribute(_ a: Attribute) throws -> Value {
        let base = try emitExpression(a.value)
        if case .structure(let name, let members) = base.type {
            guard let k = members.firstIndex(where: { $0.0 == a.attr }) else {
                throw PyShaderError("`\(name)` has no field `\(a.attr)`", line: a.lineno)
            }
            return emit(.opCompositeExtract, type: members[k].1, [base.id, UInt32(k)])
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

    private func emitSubscript(_ s: Subscript) throws -> Value {
        // Rooted in a variable: read through a pointer so dynamic indices work on arrays and matrices.
        if !isFloatArrayHandle(s.value), let p = try pointer(for: .subscriptExpr(s), line: s.lineno) {
            return load(p.ptr, type: p.type)
        }
        let base = try emitExpression(s.value)
        if case .floatArray(let argument) = base.type {
            let index = try emitExpression(s.slice)
            guard index.type.isScalar, index.type.isInt else {
                throw PyShaderError("array index must be an integer, got `\(index.type)`", line: s.lineno)
            }
            return try compiler.loadArgumentArrayElement(argument, index: index, from: self, line: s.lineno)
        }
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
            return emit(.opVectorExtractDynamic, type: base.type.elementType!, [base.id, index])
        case .matrix, .array, .tuple:
            guard let k = constantIndex(s.slice) else {
                throw PyShaderError("dynamic indexing needs the `\(base.type)` in a variable", line: s.lineno)
            }
            let i = k < 0 ? k + base.type.count : k
            guard (0..<base.type.count).contains(i), let elem = base.type.elementType(at: i) else {
                throw PyShaderError("index \(k) is out of range for `\(base.type)`", line: s.lineno)
            }
            return emit(.opCompositeExtract, type: elem, [base.id, UInt32(i)])
        default:
            throw PyShaderError("`\(base.type)` cannot be indexed", line: s.lineno)
        }
    }

    private func isFloatArrayHandle(_ e: Expression) -> Bool {
        if case .name(let n) = e, lookupHandle(n.id) != nil { return true }
        return false
    }

    /// Emits an integer index value (constant or dynamic) for component access.
    func emitIndex(_ e: Expression, count: Int, line: Int) throws -> SpirvId {
        if let k = constantIndex(e) {
            let i = k < 0 ? k + count : k
            guard (0..<count).contains(i) else {
                throw PyShaderError("index \(k) is out of range for a \(count)-component vector", line: line)
            }
            return builder.constant(int: i)
        }
        if case .slice = e {
            throw PyShaderError("slicing is not supported; use swizzles (`v.xy`)", line: line)
        }
        let v = try emitExpression(e)
        guard v.type.isScalar, v.type.isInt else {
            throw PyShaderError("index must be an integer, got `\(v.type)`", line: line)
        }
        return v.id
    }

    // MARK: Conditional expression

    private func emitIfExp(_ i: IfExp) throws -> Value {
        // Both arms are evaluated (shader code has no side effects); OpSelect picks.
        let cond = try emitCondition(i.test, line: i.lineno)
        let a = try emitExpression(i.body)
        let b = try emitExpression(i.orElse)
        let (x, y) = try promote(a, b, line: i.lineno)
        var c = cond
        if x.type.isVector {
            // SPIR-V 1.0 requires the condition to match the result's arity.
            let n = x.type.componentCount
            c = emit(.opCompositeConstruct, type: .bool(n), Array(repeating: cond.id, count: n))
        }
        return emit(.opSelect, type: x.type, [c.id, x.id, y.id])
    }

    // MARK: Calls

    private func emitCall(_ c: Call) throws -> Value {
        if case .name(let n) = c.fun, let type = program.structs[n.id] {
            return try constructStruct(type, c, line: c.lineno)
        }
        guard c.keywords.isEmpty else {
            throw PyShaderError("keyword arguments are not supported in shader calls", line: c.lineno)
        }
        // (lambda x: ...)(3)
        if case .lambda(let l) = c.fun {
            let args = try c.args.map { try emitExpression($0) }
            return try compiler.callLambda(LambdaTemplate(name: "<lambda>", lambda: l, line: l.lineno), args: args, from: self, line: c.lineno)
        }
        let name: String
        switch c.fun {
        case .name(let n): name = n.id
        case .attribute(let a):
            // pyshader.sin(...) style access
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
        if let v = try callBuiltin(name, args, line: c.lineno) {
            return v
        }
        if program.globals[name] != nil {
            throw PyShaderError("`\(name)` is a constant, not a function", line: c.lineno)
        }
        throw PyShaderError("unknown function `\(name)`", line: c.lineno)
    }

    /// `Name(a, b)` / `Name(field=a, ...)`: every field exactly once, positionally in
    /// declaration order or by keyword, each converted to its field's type.
    private func constructStruct(_ type: ShaderType, _ c: Call, line: Int) throws -> Value {
        guard case .structure(let name, let members) = type else { preconditionFailure() }
        var values: [Value?] = Array(repeating: nil, count: members.count)
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
        return emit(.opCompositeConstruct, type: type, values.map { $0!.id })
    }

    private func callUser(_ fn: ShaderFunctionSignature, _ args: [Value], line: Int) throws -> Value {
        guard fn.name != functionName else {
            throw PyShaderError("recursion is not allowed in shader code (`\(fn.name)` calls itself)", line: line)
        }
        guard !program.isEntry(fn.name) else {
            throw PyShaderError("`\(fn.name)` is the entry point and cannot be called", line: line)
        }
        guard args.count == fn.params.count else {
            throw PyShaderError("`\(fn.name)` takes \(fn.params.count) argument(s), got \(args.count)", line: line)
        }
        var ids: [UInt32] = []
        for (arg, param) in zip(args, fn.params) {
            let v = try coerce(arg, to: param.type, line: line)
            ids.append(v.id)
        }
        compiler.recordCall(from: functionName, to: fn.name)
        return emit(.opFunctionCall, type: fn.returnType, [fn.id] + ids)
    }

    /// Vector / scalar constructors: `float4(1, 0, 0, 1)`, `float3(v2, z)`, `float4(0.5)`, `int(x)`.
    func construct(_ type: ShaderType, _ args: [Value], line: Int) throws -> Value {
        if type.isMatrix { return try constructMatrix(type, args, line: line) }
        let n = type.componentCount
        let elem = type.elementType!
        if args.isEmpty {
            return Value(id: builder.zero(of: type), type: type)
        }
        if type.isScalar {
            guard args.count == 1 else {
                throw PyShaderError("`\(type)()` takes exactly one argument", line: line)
            }
            let a = args[0]
            if a.type.isVector {
                throw PyShaderError("cannot convert `\(a.type)` to `\(type)`; pick a component first", line: line)
            }
            return try convert(a, to: type, line: line)
        }
        if args.count == 1 {
            let a = args[0]
            if a.type.isScalar {
                let s = try convert(a, to: elem, line: line)
                if isLiteral(s.id) {
                    return Value(id: builder.constantComposite(type: type, elements: Array(repeating: s.id, count: n)), type: type)
                }
                return emit(.opCompositeConstruct, type: type, Array(repeating: s.id, count: n))
            }
            if a.type.componentCount == n {
                return try convert(a, to: type, line: line)
            }
            if a.type.componentCount > n {
                let v = try convert(a, to: a.type.with(components: a.type.componentCount)!.withKind(elem.scalarKind!), line: line)
                return swizzle(v, Array(0..<n))
            }
            throw PyShaderError("`\(type)` needs \(n) components, `\(a.type)` has \(a.type.componentCount)", line: line)
        }
        // Flatten all arguments into scalar components.
        var components: [SpirvId] = []
        for a in args {
            let converted = try convert(a, to: a.type.withKind(elem.scalarKind!), line: line)
            if converted.type.isScalar {
                components.append(converted.id)
            } else {
                for i in 0..<converted.type.componentCount {
                    components.append(swizzle(converted, [i]).id)
                }
            }
        }
        guard components.count == n else {
            throw PyShaderError("`\(type)` needs \(n) components, got \(components.count)", line: line)
        }
        if components.allSatisfy(isLiteral) {
            return Value(id: builder.constantComposite(type: type, elements: components), type: type)
        }
        return emit(.opCompositeConstruct, type: type, components)
    }
}

extension ShaderType {
    /// Same arity with a different element kind.
    func withKind(_ kind: ScalarKind) -> ShaderType {
        switch self {
        case .scalar: return .scalar(kind)
        case .vector(_, let n): return .vector(kind, n)
        default: return self
        }
    }
}
