//
//  FunctionEmitter.swift
//  PyShader
//
//  Emits one SPIR-V function from a Python function body. Locals are
//  `OpVariable`s in the entry block; every read is an `OpLoad` and every
//  write an `OpStore`, which keeps structured control flow trivial (no phi
//  nodes). Drivers fold the loads/stores away.
//

import SpirvCore
import PySwiftAST

final class FunctionEmitter {
    let compiler: ShaderCompiler
    var builder: SpirvModuleBuilder { compiler.builder }
    var program: ShaderProgram { compiler.program }

    let functionName: String
    let returnType: ShaderType
    /// Called for `return` without a value (and for falling off the end) in a non-void function.
    let implicitReturn: ((FunctionEmitter) throws -> Value)?

    private var variableDecls: [SpirvInstruction] = []
    private var body: [SpirvInstruction] = []
    private var locals: [String: LocalVariable] = [:]
    /// Names bound to compile-time resource handles (`FloatArray` arguments) rather than variables.
    private var handles: [String: ShaderType] = [:]

    /// True when the current block already ended with a terminator.
    private(set) var terminated = false
    /// False when the current block can never execute (code after `return`/`break`).
    private var reachable = true
    private var loops: [(continueLabel: SpirvId, mergeLabel: SpirvId)] = []

    init(compiler: ShaderCompiler, name: String, returnType: ShaderType, implicitReturn: ((FunctionEmitter) throws -> Value)? = nil) {
        self.compiler = compiler
        self.functionName = name
        self.returnType = returnType
        self.implicitReturn = implicitReturn
    }

    // MARK: Driving

    /// Emits a complete function from Python statements and hands it to the module builder.
    func emitFunction(id: SpirvId, params: [(name: String, type: ShaderType)], body statements: [Statement], line: Int) throws {
        let paramIds = beginFunction(params)
        try emitBlock(statements)

        if !terminated {
            if !reachable {
                terminate(.init(.opUnreachable))
            } else if returnType == .void {
                terminate(.init(.opReturn))
            } else if let implicitReturn {
                let v = try implicitReturn(self)
                terminate(.init(.opReturnValue, [v.id]))
            } else {
                throw PyShaderError("`\(functionName)` must return a `\(returnType)` on every path", line: line)
            }
        }
        finishFunction(id: id, paramIds: paramIds, returnType: returnType)
    }

    /// Emits a parameterless void function whose body is built in Swift (the entry-point wrappers).
    func emitWrapper(id: SpirvId, _ body: (FunctionEmitter) throws -> Void) throws {
        let paramIds = beginFunction([])
        try body(self)
        if !terminated { terminate(.init(.opReturn)) }
        finishFunction(id: id, paramIds: paramIds, returnType: .void)
    }

    /// `if cond: return` in a void function, as a structured selection.
    func emitReturnIf(_ cond: Value) {
        let thenLabel = builder.allocate()
        let mergeLabel = builder.allocate()
        emit(.init(.opSelectionMerge, [mergeLabel, SpirvSelectionControl.none.rawValue]))
        terminate(.init(.opBranchConditional, [cond.id, thenLabel, mergeLabel]))
        label(thenLabel, reachable: true)
        terminate(.init(.opReturn))
        label(mergeLabel, reachable: true)
    }

    /// Emits a lambda body; the return type is whatever the expression evaluates to.
    func emitLambda(id: SpirvId, params: [(name: String, type: ShaderType)], body expr: Expression, line: Int) throws -> ShaderType {
        let paramIds = beginFunction(params)
        let v = try emitExpression(expr)
        guard v.type.isStorable else {
            throw PyShaderError("lambda must produce a value, got `\(v.type)`", line: line)
        }
        terminate(.init(.opReturnValue, [v.id]))
        finishFunction(id: id, paramIds: paramIds, returnType: v.type)
        return v.type
    }

    /// Opens the entry block and copies parameters into locals so Python code can reassign them.
    private func beginFunction(_ params: [(name: String, type: ShaderType)]) -> [(SpirvId, ShaderType)] {
        var paramIds: [(SpirvId, ShaderType)] = []
        body.append(.init(.opLabel, [builder.allocate()]))
        for p in params {
            if case .floatArray = p.type {
                handles[p.name] = p.type
                continue
            }
            let pid = builder.allocate()
            paramIds.append((pid, p.type))
            let v = declareLocal(p.name, type: p.type)
            store(v.ptr, pid)
        }
        return paramIds
    }

    /// Assembles header + entry label + OpVariables + body and adds it to the module.
    private func finishFunction(id: SpirvId, paramIds: [(SpirvId, ShaderType)], returnType: ShaderType) {
        let fnType = ShaderType.function(returns: returnType, params: paramIds.map(\.1))
        var out: [SpirvInstruction] = [
            .init(.opFunction, [builder.type(returnType), id, SpirvFunctionControl.none.rawValue, builder.type(fnType)])
        ]
        for (pid, type) in paramIds {
            out.append(.init(.opFunctionParameter, [builder.type(type), pid]))
        }
        // OpVariables must be the first instructions of the entry block.
        out.append(body[0])
        out.append(contentsOf: variableDecls)
        out.append(contentsOf: body.dropFirst())
        out.append(.init(.opFunctionEnd))
        builder.addFunction(out)
    }

    /// `discard()`: OpKill ends the block; anything after it is dead code.
    func emitDiscard(line: Int) throws -> Value {
        terminate(.init(.opKill))
        return Value(id: 0, type: .void)
    }

    // MARK: Instruction helpers

    func emit(_ instr: SpirvInstruction) {
        precondition(!terminated, "emitting into a terminated block")
        body.append(instr)
    }

    /// Emits an instruction with a fresh result id: `%id = op %type ...`.
    @discardableResult
    func emit(_ op: SpirvOp, type: ShaderType, _ operands: [UInt32]) -> Value {
        let id = builder.allocate()
        emit(.init(op, [builder.type(type), id] + operands))
        return Value(id: id, type: type)
    }

    func emitExt(_ inst: GLSLstd450, type: ShaderType, _ operands: [UInt32]) -> Value {
        emit(.opExtInst, type: type, [builder.glslExtId, inst.rawValue] + operands)
    }

    private func terminate(_ instr: SpirvInstruction) {
        emit(instr)
        terminated = true
    }

    private func label(_ id: SpirvId, reachable: Bool) {
        body.append(.init(.opLabel, [id]))
        terminated = false
        self.reachable = reachable
    }

    /// Makes sure there is an open block to emit into (code after `return`/`break` lands in a dead block).
    private func ensureOpen() {
        if terminated { label(builder.allocate(), reachable: false) }
    }

    // MARK: Locals

    func lookupLocal(_ name: String) -> LocalVariable? { locals[name] }
    func lookupHandle(_ name: String) -> ShaderType? { handles[name] }

    @discardableResult
    func declareLocal(_ name: String, type: ShaderType) -> LocalVariable {
        let ptrType = builder.type(.pointer(.function, type))
        let id = builder.allocate()
        variableDecls.append(.init(.opVariable, [ptrType, id, SpirvStorageClass.function.rawValue]))
        builder.name(id, name)
        let v = LocalVariable(ptr: id, type: type)
        locals[name] = v
        return v
    }

    /// An anonymous temporary variable (used for loop bookkeeping).
    func declareTemp(type: ShaderType) -> LocalVariable {
        let ptrType = builder.type(.pointer(.function, type))
        let id = builder.allocate()
        variableDecls.append(.init(.opVariable, [ptrType, id, SpirvStorageClass.function.rawValue]))
        return LocalVariable(ptr: id, type: type)
    }

    func load(_ ptr: SpirvId, type: ShaderType) -> Value {
        emit(.opLoad, type: type, [ptr])
    }

    func store(_ ptr: SpirvId, _ value: SpirvId) {
        emit(.init(.opStore, [ptr, value]))
    }

    // MARK: LValues

    func load(_ lvalue: LValue) -> Value {
        switch lvalue {
        case .variable(let ptr, let t):
            return load(ptr, type: t)
        case .component(let ptr, let index, let vt):
            let elem = vt.elementType!
            let chain = emit(.opAccessChain, type: .pointer(.function, elem), [ptr, index])
            return load(chain.id, type: elem)
        case .swizzle(let ptr, let vt, let indices):
            let whole = load(ptr, type: vt)
            return swizzle(whole, indices)
        }
    }

    func store(_ lvalue: LValue, _ value: Value, line: Int) throws {
        switch lvalue {
        case .variable(let ptr, let t):
            let v = try coerce(value, to: t, line: line)
            store(ptr, v.id)
        case .component(let ptr, let index, let vt):
            let elem = vt.elementType!
            let v = try coerce(value, to: elem, line: line)
            let chain = emit(.opAccessChain, type: .pointer(.function, elem), [ptr, index])
            store(chain.id, v.id)
        case .swizzle(let ptr, let vt, let indices):
            guard Swift.Set(indices).count == indices.count else {
                throw PyShaderError("cannot assign to a swizzle with repeated components", line: line)
            }
            let target = vt.with(components: indices.count)!
            let v = try coerce(value, to: target, line: line)
            if indices.count == 1 {
                let elem = vt.elementType!
                let chain = emit(.opAccessChain, type: .pointer(.function, elem), [ptr, builder.constant(int: indices[0])])
                store(chain.id, v.id)
                return
            }
            // Merge the new components into the old vector: indices >= n pick from `v`.
            let old = load(ptr, type: vt)
            let n = vt.componentCount
            let shuffle: [UInt32] = (0..<n).map { i in
                if let k = indices.firstIndex(of: i) { return UInt32(n + k) }
                return UInt32(i)
            }
            let merged = emit(.opVectorShuffle, type: vt, [old.id, v.id] + shuffle)
            store(ptr, merged.id)
        }
    }

    /// A pointer to a local variable or into one (`a[i]`, `m[i][j]`, `a[i].x`), for
    /// expressions that can be read and written in place. Nil when the expression is
    /// not rooted in a variable.
    func pointer(for expr: Expression, line: Int) throws -> (ptr: SpirvId, type: ShaderType)? {
        switch expr {
        case .name(let n):
            guard let local = locals[n.id] else { return nil }
            return (local.ptr, local.type)
        case .subscriptExpr(let sub):
            guard let base = try pointer(for: sub.value, line: line) else { return nil }
            guard let elem = base.type.elementType(at: nil), !base.type.isFloatArray else {
                if case .tuple = base.type {
                    guard let k = constantIndex(sub.slice), let member = base.type.elementType(at: k) else {
                        throw PyShaderError("tuple index must be a constant", line: line)
                    }
                    let chain = emit(.opAccessChain, type: .pointer(.function, member), [base.ptr, builder.constant(int: k)])
                    return (chain.id, member)
                }
                return nil
            }
            let index = try emitIndex(sub.slice, count: base.type.count, line: line)
            let chain = emit(.opAccessChain, type: .pointer(.function, elem), [base.ptr, index])
            return (chain.id, elem)
        case .attribute(let a):
            guard let base = try pointer(for: a.value, line: line) else { return nil }
            if case .structure(let name, let members) = base.type {
                guard let k = members.firstIndex(where: { $0.0 == a.attr }) else {
                    throw PyShaderError("`\(name)` has no field `\(a.attr)`", line: line)
                }
                let chain = emit(.opAccessChain, type: .pointer(.function, members[k].1), [base.ptr, builder.constant(int: k)])
                return (chain.id, members[k].1)
            }
            guard let indices = Swizzle.indices(for: a.attr), indices.count == 1, base.type.isVector else { return nil }
            guard indices[0] < base.type.componentCount else {
                throw PyShaderError("component \(indices[0]) is out of range for `\(base.type)`", line: line)
            }
            let elem = base.type.elementType!
            let chain = emit(.opAccessChain, type: .pointer(.function, elem), [base.ptr, builder.constant(int: indices[0])])
            return (chain.id, elem)
        default:
            return nil
        }
    }

    /// Resolves an assignment target into an LValue.
    func lvalue(for target: Expression, line: Int) throws -> LValue {
        switch target {
        case .name(let n):
            guard let local = locals[n.id] else {
                throw PyShaderError("`\(n.id)` is not defined", line: line)
            }
            return .variable(ptr: local.ptr, type: local.type)
        case .attribute(let a):
            guard let base = try pointer(for: a.value, line: line) else {
                throw PyShaderError("can only assign to components of a variable (e.g. `color.rgb = ...`)", line: line)
            }
            if case .structure = base.type {
                guard let p = try pointer(for: target, line: line) else {
                    throw PyShaderError("can only assign to a field of a variable", line: line)
                }
                return .variable(ptr: p.ptr, type: p.type)
            }
            guard base.type.isVector else {
                throw PyShaderError("`\(base.type)` has no component `\(a.attr)`", line: line)
            }
            guard let indices = Swizzle.indices(for: a.attr) else {
                throw PyShaderError("`\(a.attr)` is not a vector component", line: line)
            }
            if let bad = indices.first(where: { $0 >= base.type.componentCount }) {
                throw PyShaderError("component \(bad) is out of range for `\(base.type)`", line: line)
            }
            return .swizzle(ptr: base.ptr, vectorType: base.type, indices: indices)
        case .subscriptExpr:
            guard let p = try pointer(for: target, line: line) else {
                throw PyShaderError("can only index into a variable", line: line)
            }
            return .variable(ptr: p.ptr, type: p.type)
        default:
            throw PyShaderError("unsupported assignment target", line: line)
        }
    }

    func constantIndex(_ e: Expression) -> Int? {
        switch e {
        case .constant(let c):
            if case .int(let v) = c.value { return v }
        case .unaryOp(let u):
            if u.op == .uSub, let v = constantIndex(u.operand) { return -v }
        default: break
        }
        return nil
    }

    // MARK: Statements

    func emitBlock(_ statements: [Statement]) throws {
        for s in statements {
            ensureOpen()
            try emitStatement(s)
        }
    }

    private func emitStatement(_ stmt: Statement) throws {
        switch stmt {
        case .pass, .blank:
            break

        case .expr(let e):
            if case .constant = e.value { return }   // docstrings
            _ = try emitExpression(e.value)

        case .assign(let a):
            try emitAssign(a)

        case .annAssign(let a):
            try emitAnnAssign(a)

        case .augAssign(let a):
            let target = try lvalue(for: a.target, line: a.lineno)
            let current = load(target)
            let rhs = try emitExpression(a.value)
            let result = try binary(a.op, current, rhs, line: a.lineno)
            try store(target, result, line: a.lineno)

        case .returnStmt(let r):
            try emitReturn(r)

        case .ifStmt(let i):
            try emitIf(i)

        case .whileStmt(let w):
            try emitWhile(w)

        case .forStmt(let f):
            try emitFor(f)

        case .breakStmt(let b):
            guard let loop = loops.last else { throw PyShaderError("`break` outside loop", line: b.lineno) }
            terminate(.init(.opBranch, [loop.mergeLabel]))

        case .continueStmt(let c):
            guard let loop = loops.last else { throw PyShaderError("`continue` outside loop", line: c.lineno) }
            terminate(.init(.opBranch, [loop.continueLabel]))

        case .functionDef(let d):
            throw PyShaderError("nested functions are not supported; define `\(d.name)` at module level", line: d.lineno)
        case .classDef(let c):
            throw PyShaderError("classes are not supported in shader code yet", line: c.lineno)
        case .importStmt(let i):
            throw PyShaderError("imports are not allowed inside functions", line: i.lineno)
        case .importFrom(let i):
            throw PyShaderError("imports are not allowed inside functions", line: i.lineno)
        case .tryStmt(let t):
            throw PyShaderError("try/except is not available in shader code", line: t.lineno)
        case .raise(let r):
            throw PyShaderError("raise is not available in shader code", line: r.lineno)
        case .assertStmt(let a):
            throw PyShaderError("assert is not available in shader code", line: a.lineno)
        case .withStmt(let w):
            throw PyShaderError("with is not available in shader code", line: w.lineno)
        case .match(let m):
            throw PyShaderError("match is not supported yet; use if/elif", line: m.lineno)
        case .delete(let d):
            throw PyShaderError("del is not available in shader code", line: d.lineno)
        case .global(let g):
            throw PyShaderError("module constants are read-only; `global` is not needed", line: g.lineno)
        default:
            throw PyShaderError("unsupported statement", line: stmt.lineno)
        }
    }

    private func emitAssign(_ a: Assign) throws {
        // `x, y = uv` / `a, b = 1, 2`
        if a.targets.count == 1, case .tuple(let t) = a.targets[0] {
            try emitUnpack(targets: t.elts, value: a.value, line: a.lineno)
            return
        }
        if a.targets.count == 1, case .list(let l) = a.targets[0] {
            try emitUnpack(targets: l.elts, value: a.value, line: a.lineno)
            return
        }
        let value = try emitExpression(a.value)
        for target in a.targets {
            try assign(target, value, line: a.lineno)
        }
    }

    private func emitUnpack(targets: [Expression], value: Expression, line: Int) throws {
        var values: [Value] = []
        switch value {
        case .tuple(let t):
            guard t.elts.count == targets.count else {
                throw PyShaderError("cannot unpack \(t.elts.count) values into \(targets.count) targets", line: line)
            }
            values = try t.elts.map { try emitExpression($0) }
        case .list(let l):
            guard l.elts.count == targets.count else {
                throw PyShaderError("cannot unpack \(l.elts.count) values into \(targets.count) targets", line: line)
            }
            values = try l.elts.map { try emitExpression($0) }
        default:
            let v = try emitExpression(value)
            switch v.type {
            case .vector(_, let n) where n == targets.count:
                values = (0..<n).map { swizzle(v, [$0]) }
            case .tuple(let members) where members.count == targets.count:
                values = members.enumerated().map { i, t in emit(.opCompositeExtract, type: t, [v.id, UInt32(i)]) }
            case .array(let elem, let n) where n == targets.count:
                values = (0..<n).map { emit(.opCompositeExtract, type: elem, [v.id, UInt32($0)]) }
            default:
                throw PyShaderError("cannot unpack `\(v.type)` into \(targets.count) targets", line: line)
            }
        }
        for (target, v) in zip(targets, values) {
            try assign(target, v, line: line)
        }
    }

    /// Assigns to a plain name (declaring it on first use) or to any other lvalue.
    private func assign(_ target: Expression, _ value: Value, line: Int) throws {
        if case .name(let n) = target {
            if let local = locals[n.id] {
                try store(.variable(ptr: local.ptr, type: local.type), value, line: line)
            } else {
                guard value.type.isStorable else {
                    throw PyShaderError("cannot store a `\(value.type)` in a variable", line: line)
                }
                let local = declareLocal(n.id, type: value.type)
                store(local.ptr, value.id)
            }
            return
        }
        let lv = try lvalue(for: target, line: line)
        try store(lv, value, line: line)
    }

    private func emitAnnAssign(_ a: AnnAssign) throws {
        guard case .name(let n) = a.target else {
            throw PyShaderError("only plain variables can be annotated", line: a.lineno)
        }
        var type = try program.resolveType(a.annotation, line: a.lineno)
        if case .array(let elem, -1) = type {
            // `xs: list[float4] = [...]` — the length is the value's.
            guard let valueExpr = a.value else {
                throw PyShaderError("`\(n.id)`: a list needs a value to fix its length", line: a.lineno)
            }
            let value = try emitExpression(valueExpr)
            guard case .array(let got, let length) = value.type else {
                throw PyShaderError("`\(n.id)` is a list, got `\(value.type)`", line: a.lineno)
            }
            type = .array(elem, length)
            let local = locals[n.id] ?? declareLocal(n.id, type: type)
            guard local.type == type else {
                throw PyShaderError("`\(n.id)` is already a `\(local.type)`", line: a.lineno)
            }
            let converted = got == elem ? value : try coerceArray(value, to: type, line: a.lineno)
            store(local.ptr, converted.id)
            return
        }
        let local: LocalVariable
        if let existing = locals[n.id] {
            guard existing.type == type else {
                throw PyShaderError("`\(n.id)` is already a `\(existing.type)`, cannot redeclare as `\(type)`", line: a.lineno)
            }
            local = existing
        } else {
            local = declareLocal(n.id, type: type)
        }
        if let valueExpr = a.value {
            let value = try emitExpression(valueExpr)
            try store(.variable(ptr: local.ptr, type: local.type), value, line: a.lineno)
        }
    }

    private func emitReturn(_ r: Return) throws {
        if returnType == .void {
            if let v = r.value {
                if case .constant(let c) = v, case .none = c.value {
                    terminate(.init(.opReturn))
                    return
                }
                throw PyShaderError("`\(functionName)` has no return type annotation, it cannot return a value", line: r.lineno)
            }
            terminate(.init(.opReturn))
            return
        }
        let value: Value
        if let expr = r.value, !isNoneLiteral(expr) {
            if case .tuple(let members) = returnType, case .tuple(let literal) = expr {
                // `return a, b` against `-> tuple[...]`: convert each element to its slot.
                guard literal.elts.count == members.count else {
                    throw PyShaderError("`\(functionName)` returns \(members.count) values, got \(literal.elts.count)", line: r.lineno)
                }
                var ids: [SpirvId] = []
                for (e, t) in zip(literal.elts, members) {
                    ids.append(try coerce(try emitExpression(e), to: t, line: r.lineno).id)
                }
                value = emit(.opCompositeConstruct, type: returnType, ids)
            } else {
                let raw = try emitExpression(expr)
                value = try coerce(raw, to: returnType, line: r.lineno)
            }
        } else if let implicitReturn {
            value = try implicitReturn(self)
        } else {
            throw PyShaderError("`\(functionName)` must return a `\(returnType)`", line: r.lineno)
        }
        terminate(.init(.opReturnValue, [value.id]))
    }

    private func isNoneLiteral(_ e: Expression) -> Bool {
        if case .constant(let c) = e, case .none = c.value { return true }
        return false
    }

    // MARK: Control flow

    private func emitIf(_ i: If) throws {
        let cond = try emitCondition(i.test, line: i.lineno)
        let thenLabel = builder.allocate()
        let mergeLabel = builder.allocate()
        let elseLabel = i.orElse.isEmpty ? mergeLabel : builder.allocate()
        let entryReachable = reachable

        emit(.init(.opSelectionMerge, [mergeLabel, SpirvSelectionControl.none.rawValue]))
        terminate(.init(.opBranchConditional, [cond.id, thenLabel, elseLabel]))

        label(thenLabel, reachable: entryReachable)
        try emitBlock(i.body)
        let thenFallsThrough = !terminated && reachable
        if !terminated { terminate(.init(.opBranch, [mergeLabel])) }

        var elseFallsThrough = entryReachable
        if !i.orElse.isEmpty {
            label(elseLabel, reachable: entryReachable)
            try emitBlock(i.orElse)
            elseFallsThrough = !terminated && reachable
            if !terminated { terminate(.init(.opBranch, [mergeLabel])) }
        }

        label(mergeLabel, reachable: thenFallsThrough || elseFallsThrough)
    }

    private func emitWhile(_ w: While) throws {
        guard w.orElse.isEmpty else {
            throw PyShaderError("`while ... else` is not supported", line: w.lineno)
        }
        let header = builder.allocate()
        let condLabel = builder.allocate()
        let bodyLabel = builder.allocate()
        let continueLabel = builder.allocate()
        let mergeLabel = builder.allocate()
        let entryReachable = reachable

        terminate(.init(.opBranch, [header]))
        label(header, reachable: entryReachable)
        emit(.init(.opLoopMerge, [mergeLabel, continueLabel, SpirvLoopControl.none.rawValue]))
        terminate(.init(.opBranch, [condLabel]))

        label(condLabel, reachable: entryReachable)
        let cond = try emitCondition(w.test, line: w.lineno)
        terminate(.init(.opBranchConditional, [cond.id, bodyLabel, mergeLabel]))

        label(bodyLabel, reachable: entryReachable)
        loops.append((continueLabel, mergeLabel))
        try emitBlock(w.body)
        loops.removeLast()
        if !terminated { terminate(.init(.opBranch, [continueLabel])) }

        label(continueLabel, reachable: entryReachable)
        terminate(.init(.opBranch, [header]))

        label(mergeLabel, reachable: entryReachable)
    }

    private func emitFor(_ f: For) throws {
        guard f.orElse.isEmpty else {
            throw PyShaderError("`for ... else` is not supported", line: f.lineno)
        }
        guard case .name(let target) = f.target else {
            throw PyShaderError("for-loop target must be a single variable", line: f.lineno)
        }
        guard case .call(let call) = f.iter, case .name(let fn) = call.fun, fn.id == "range" else {
            throw PyShaderError("for-loops can only iterate `range(...)`", line: f.lineno)
        }
        guard call.keywords.isEmpty, (1...3).contains(call.args.count) else {
            throw PyShaderError("range() takes 1 to 3 positional arguments", line: f.lineno)
        }

        let rangeArgs = try call.args.map { arg -> Value in
            let v = try emitExpression(arg)
            guard v.type.isScalar, v.type.isInt else {
                throw PyShaderError("range() arguments must be integers, got `\(v.type)`", line: f.lineno)
            }
            return v
        }
        let intType = rangeArgs[0].type
        let one = builder.constant(int: 1, type: intType)
        let start: Value
        let stop: Value
        let step: Value
        switch rangeArgs.count {
        case 1:
            start = Value(id: builder.constant(int: 0, type: intType), type: intType)
            stop = rangeArgs[0]
            step = Value(id: one, type: intType)
        case 2:
            start = rangeArgs[0]
            stop = try coerce(rangeArgs[1], to: intType, line: f.lineno)
            step = Value(id: one, type: intType)
        default:
            start = rangeArgs[0]
            stop = try coerce(rangeArgs[1], to: intType, line: f.lineno)
            step = try coerce(rangeArgs[2], to: intType, line: f.lineno)
        }
        let constantStep = constantInt(call.args[safe: 2])

        let counter: LocalVariable
        if let existing = locals[target.id] {
            guard existing.type == intType else {
                throw PyShaderError("loop variable `\(target.id)` is already a `\(existing.type)`", line: f.lineno)
            }
            counter = existing
        } else {
            counter = declareLocal(target.id, type: intType)
        }
        store(counter.ptr, start.id)

        let header = builder.allocate()
        let condLabel = builder.allocate()
        let bodyLabel = builder.allocate()
        let continueLabel = builder.allocate()
        let mergeLabel = builder.allocate()
        let entryReachable = reachable

        terminate(.init(.opBranch, [header]))
        label(header, reachable: entryReachable)
        emit(.init(.opLoopMerge, [mergeLabel, continueLabel, SpirvLoopControl.none.rawValue]))
        terminate(.init(.opBranch, [condLabel]))

        label(condLabel, reachable: entryReachable)
        let i = load(counter.ptr, type: intType)
        let signed = intType.scalarKind!.isSigned
        let lessOp: SpirvOp = signed ? .opSLessThan : .opULessThan
        let greaterOp: SpirvOp = signed ? .opSGreaterThan : .opUGreaterThan
        let cond: Value
        if let constantStep {
            cond = emit(constantStep < 0 ? greaterOp : lessOp, type: .bool, [i.id, stop.id])
        } else {
            // Python semantics for a runtime step sign: (step > 0) ? i < stop : i > stop
            let zero = builder.constant(int: 0, type: intType)
            let positive = emit(greaterOp, type: .bool, [step.id, zero])
            let lt = emit(lessOp, type: .bool, [i.id, stop.id])
            let gt = emit(greaterOp, type: .bool, [i.id, stop.id])
            cond = emit(.opSelect, type: .bool, [positive.id, lt.id, gt.id])
        }
        terminate(.init(.opBranchConditional, [cond.id, bodyLabel, mergeLabel]))

        label(bodyLabel, reachable: entryReachable)
        loops.append((continueLabel, mergeLabel))
        try emitBlock(f.body)
        loops.removeLast()
        if !terminated { terminate(.init(.opBranch, [continueLabel])) }

        label(continueLabel, reachable: entryReachable)
        let cur = load(counter.ptr, type: intType)
        let next = emit(.opIAdd, type: intType, [cur.id, step.id])
        store(counter.ptr, next.id)
        terminate(.init(.opBranch, [header]))

        label(mergeLabel, reachable: entryReachable)
    }

    private func constantInt(_ expr: Expression?) -> Int? {
        guard let expr else { return 1 }
        switch expr {
        case .constant(let c):
            if case .int(let v) = c.value { return v }
        case .unaryOp(let u):
            if u.op == .uSub, let v = constantInt(u.operand) { return -v }
        default:
            break
        }
        return nil
    }

    /// Evaluates an expression used as a branch condition; must be a scalar bool.
    func emitCondition(_ expr: Expression, line: Int) throws -> Value {
        let v = try emitExpression(expr)
        return try truthy(v, line: line)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
