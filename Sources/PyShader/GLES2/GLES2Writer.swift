//
//  GLES2Writer.swift
//  PyShader
//
//  Writes one GLSL ES 1.00 function from a Python function body. As in the
//  SPIR-V emitter, every local is declared at the top of the function, so a
//  variable first assigned inside an `if` is still there after it.
//
//  OpenGL ES 2 only promises what GLSL ES 1.00's Appendix A lists: `for`
//  loops over constant ranges whose counter the body leaves alone, and array
//  and vector indices built from constants and those counters. Anything
//  else is an error at its line rather than a shader that fails on a phone.
//

import PySwiftAST

final class GLES2Writer {
    unowned let compiler: GLES2Compiler
    var program: ShaderProgram { compiler.program }

    let functionName: String
    let returnType: ShaderType
    let implicitReturn: ((GLES2Writer) throws -> GLValue)?
    /// The top-level declarations this function needs (`fn:…`, `struct:…`, `uniform:…`).
    var uses: Swift.Set<String> = []

    private var declarations: [String] = []
    /// Lines being written, each with its indentation; `capture` writes into a fresh one.
    private var buffers: [[(indent: Int, text: String)]] = [[]]
    private var indent = 1
    private var locals: [String: (name: String, type: ShaderType)] = [:]
    private var localNames: Swift.Set<String> = []
    /// Texture parameters: names, not values.
    private var handles: [String: ShaderType] = [:]
    private var declaredGlobals: Swift.Set<String> = []
    /// The `for` loops being written, innermost last: Python name, GLSL name.
    private var counters: [(python: String, gl: String)] = []
    private var finishedCounters: Swift.Set<String> = []
    private var loopDepth = 0
    /// False once the current point can no longer be reached (after a
    /// `return`, `break`, `continue` or `discard()`).
    private(set) var falls = true
    private var tempCount = 0

    init(compiler: GLES2Compiler, name: String, returnType: ShaderType, implicitReturn: ((GLES2Writer) throws -> GLValue)? = nil) {
        self.compiler = compiler
        self.functionName = name
        self.returnType = returnType
        self.implicitReturn = implicitReturn
    }

    // MARK: Functions

    func emitFunction(glName: String, params: [(name: String, type: ShaderType)], body statements: [Statement], line: Int) throws {
        if case .array = returnType {
            throw PyShaderError("`\(functionName)` returns a list, and OpenGL ES 2 functions cannot return arrays", line: line)
        }
        var paramDecls: [String] = []
        for p in params {
            if case .texture = p.type {
                handles[p.name] = p.type
                continue
            }
            let name = localName(p.name)
            locals[p.name] = (name, p.type)
            paramDecls.append(try compiler.declaration(name, p.type, line: line, uses: &uses))
        }
        let prototype = (try typeName(returnType, line: line)) + " \(glName)(\(paramDecls.joined(separator: ", ")))"
        let text = try emitBody(prototype: prototype) { w in
            try w.emitBlock(statements)
            if w.falls && w.returnType != .void {
                guard let implicitReturn = w.implicitReturn else {
                    throw PyShaderError("`\(w.functionName)` must return a `\(w.returnType)` on every path", line: line)
                }
                w.line("return \(try implicitReturn(w).code);")
            }
        }
        compiler.record(self, prototype: prototype, text: text, glName: glName)
    }

    /// A lambda: one expression, whose type is the function's.
    func emitLambda(glName: String, params: [(name: String, type: ShaderType)], body expr: Expression, line: Int) throws -> ShaderType {
        var paramDecls: [String] = []
        for p in params {
            let name = localName(p.name)
            locals[p.name] = (name, p.type)
            paramDecls.append(try compiler.declaration(name, p.type, line: line, uses: &uses))
        }
        var result = GLValue.void
        let body = try capture { result = try emitExpression(expr) }
        guard result.type.isStorable else {
            throw PyShaderError("lambda must produce a value, got `\(result.type)`", line: line)
        }
        if case .array = result.type {
            throw PyShaderError("a lambda returning a list has no OpenGL ES 2 equivalent: functions cannot return arrays", line: line)
        }
        let prototype = (try typeName(result.type, line: line)) + " \(glName)(\(paramDecls.joined(separator: ", ")))"
        let text = try emitBody(prototype: prototype) { w in
            w.insert(body)
            w.line("return \(result.code);")
        }
        compiler.record(self, prototype: prototype, text: text, glName: glName)
        return result.type
    }

    /// `prototype { declarations; body }`, the body written by `content`.
    func emitBody(prototype: String, _ content: (GLES2Writer) throws -> Void) throws -> String {
        try content(self)
        var out = prototype + " {\n"
        for d in declarations { out += "    " + d + ";\n" }
        for (level, text) in buffers[0] { out += String(repeating: "    ", count: level) + text + "\n" }
        return out + "}\n"
    }

    // MARK: Lines

    func line(_ text: String) {
        buffers[buffers.count - 1].append((indent, text))
    }

    /// The lines `body` writes, taken out of the function to be placed later.
    func capture(_ body: () throws -> Void) rethrows -> [(indent: Int, text: String)] {
        buffers.append([])
        defer { buffers.removeLast() }
        try body()
        return buffers[buffers.count - 1]
    }

    /// Captured lines, moved `shift` levels deeper.
    func insert(_ lines: [(indent: Int, text: String)], shift: Int = 0) {
        buffers[buffers.count - 1] += lines.map { ($0.indent + shift, $0.text) }
    }

    // MARK: Locals

    func lookupLocal(_ name: String) -> (name: String, type: ShaderType)? { locals[name] }
    func lookupHandle(_ name: String) -> ShaderType? { handles[name] }
    func counter(_ name: String) -> String? { counters.last { $0.python == name }?.gl }

    /// A GLSL name for a Python local, unique in the function.
    private func localName(_ python: String) -> String {
        var name = compiler.isFreeLocalName(python) ? python : GLES2Names.prefixed(python)
        let base = name
        var n = 2
        while localNames.contains(name) {
            name = "\(base)_\(n)"
            n += 1
        }
        localNames.insert(name)
        return name
    }

    @discardableResult
    func declareLocal(_ python: String, type: ShaderType, line: Int) throws -> String {
        let name = localName(python)
        declarations.append(try compiler.declaration(name, type, line: line, uses: &uses))
        locals[python] = (name, type)
        return name
    }

    /// An anonymous local, declared with the others.
    func temp(_ type: ShaderType, line: Int) throws -> String {
        var name: String
        repeat {
            name = "pyt\(tempCount)"
            tempCount += 1
        } while localNames.contains(name)
        localNames.insert(name)
        declarations.append(try compiler.declaration(name, type, line: line, uses: &uses))
        return name
    }

    func typeName(_ type: ShaderType, line: Int) throws -> String {
        try compiler.typeName(type, line: line, uses: &uses)
    }

    /// The value in a variable of its own when it is more than a name, so it
    /// can be read several times without being computed several times.
    func materialize(_ v: GLValue, line: Int) throws -> GLValue {
        if v.literal != nil || Self.isPlain(v.code) { return v }
        let name = try temp(v.type, line: line)
        self.line(name + " = " + v.code + ";")
        return GLValue(code: name, type: v.type)
    }

    /// A name, possibly with fields and constant indices: cheap to repeat.
    static func isPlain(_ code: String) -> Bool {
        !code.isEmpty && code.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "[" || $0 == "]" }
    }

    /// The module variable `name`, when there is one.
    func lookupVariable(_ name: String, line: Int) throws -> (name: String, type: ShaderType)? {
        if let v = compiler.variable(name) {
            uses.insert("var:" + v.name)
            return v
        }
        if program.variables[name] != nil {
            throw PyShaderError("module variable `\(name)` is read before it is initialized", line: line)
        }
        return nil
    }

    // MARK: Statements

    func emitBlock(_ statements: [Statement]) throws {
        for s in statements { try emitStatement(s) }
    }

    private func emitStatement(_ stmt: Statement) throws {
        switch stmt {
        case .pass, .blank:
            break
        case .expr(let e):
            if case .constant = e.value { return }   // docstrings
            let v = try emitExpression(e.value)
            // A call may discard or call one that does; any other expression does nothing.
            if case .call = e.value, !v.code.isEmpty { line(v.code + ";") }
        case .assign(let a):
            try emitAssign(a)
        case .annAssign(let a):
            try emitAnnAssign(a)
        case .augAssign(let a):
            let target = try lvalue(for: a.target, line: a.lineno)
            let rhs = try emitExpression(a.value)
            let result = try binary(a.op, GLValue(code: target.code, type: target.type), rhs, line: a.lineno)
            try store(code: target.code, type: target.type, result, line: a.lineno)
        case .returnStmt(let r):
            try emitReturn(r)
        case .ifStmt(let i):
            try emitIf(i)
        case .whileStmt(let w):
            throw PyShaderError("OpenGL ES 2 only guarantees `for` loops over a constant `range()` (GLSL ES 1.00, Appendix A), not `while`; write it as `for i in range(N):` with a `break`", line: w.lineno)
        case .forStmt(let f):
            try emitFor(f)
        case .breakStmt(let b):
            guard loopDepth > 0 else { throw PyShaderError("`break` outside loop", line: b.lineno) }
            line("break;")
            falls = false
        case .continueStmt(let c):
            guard loopDepth > 0 else { throw PyShaderError("`continue` outside loop", line: c.lineno) }
            line("continue;")
            falls = false
        case .functionDef(let d):
            throw PyShaderError("nested functions are not supported; define `\(d.name)` at module level", line: d.lineno)
        case .classDef(let c):
            throw PyShaderError("nested classes are not supported; define `\(c.name)` at module level", line: c.lineno)
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
            try emitMatch(m)
        case .delete(let d):
            throw PyShaderError("del is not available in shader code", line: d.lineno)
        case .global(let g):
            for name in g.names {
                guard program.variables[name] != nil else {
                    throw PyShaderError("`\(name)` is not a module variable", line: g.lineno)
                }
                if locals[name] != nil {
                    throw PyShaderError("`\(name)` is assigned before its `global` declaration", line: g.lineno)
                }
                declaredGlobals.insert(name)
            }
        default:
            throw PyShaderError("unsupported statement", line: stmt.lineno)
        }
    }

    // MARK: Assignment

    private func emitAssign(_ a: Assign) throws {
        if a.targets.count == 1, case .tuple(let t) = a.targets[0] {
            try emitUnpack(targets: t.elts, value: a.value, line: a.lineno)
            return
        }
        if a.targets.count == 1, case .list(let l) = a.targets[0] {
            try emitUnpack(targets: l.elts, value: a.value, line: a.lineno)
            return
        }
        var value = try emitExpression(a.value)
        if a.targets.count > 1 { value = try materialize(value, line: a.lineno) }
        for target in a.targets {
            try assign(target, value, line: a.lineno)
        }
    }

    /// `a, b = b, a`: every value is computed before any target is written.
    private func emitUnpack(targets: [Expression], value: Expression, line: Int) throws {
        var values: [GLValue] = []
        switch value {
        case .tuple(let t):
            guard t.elts.count == targets.count else {
                throw PyShaderError("cannot unpack \(t.elts.count) values into \(targets.count) targets", line: line)
            }
            values = try t.elts.map { try copyToTemp(try emitExpression($0), line: line) }
        case .list(let l):
            guard l.elts.count == targets.count else {
                throw PyShaderError("cannot unpack \(l.elts.count) values into \(targets.count) targets", line: line)
            }
            values = try l.elts.map { try copyToTemp(try emitExpression($0), line: line) }
        default:
            // The whole value first: a target may be the value itself.
            let v = try copyToTemp(try emitExpression(value), line: line)
            switch v.type {
            case .vector(_, let n) where n == targets.count:
                values = (0..<n).map { swizzle(v, [$0]) }
            case .tuple(let members) where members.count == targets.count:
                values = members.enumerated().map { GLValue(code: "\(v.code).m\($0.offset)", type: $0.element) }
            case .array(let element, let n) where n == targets.count:
                values = (0..<n).map { GLValue(code: "\(v.code)[\($0)]", type: element) }
            default:
                throw PyShaderError("cannot unpack `\(v.type)` into \(targets.count) targets", line: line)
            }
        }
        for (target, v) in zip(targets, values) {
            try assign(target, v, line: line)
        }
    }

    /// The value in a fresh temporary, even when it is a plain name, so a
    /// later assignment cannot change it.
    private func copyToTemp(_ v: GLValue, line: Int) throws -> GLValue {
        if v.literal != nil { return v }
        let name = try temp(v.type, line: line)
        try store(code: name, type: v.type, v, line: line)
        return GLValue(code: name, type: v.type)
    }

    /// Assigns to a plain name (declaring it on first use) or to any other target.
    private func assign(_ target: Expression, _ value: GLValue, line: Int) throws {
        if case .name(let n) = target {
            if counter(n.id) != nil {
                throw PyShaderError("OpenGL ES 2 loops may not change their counter `\(n.id)` (GLSL ES 1.00, Appendix A)", line: line)
            }
            if let local = locals[n.id] {
                try store(code: local.name, type: local.type, value, line: line)
            } else if declaredGlobals.contains(n.id), let v = try lookupVariable(n.id, line: line) {
                try store(code: v.name, type: v.type, value, line: line)
            } else {
                guard value.type.isStorable else {
                    throw PyShaderError("cannot store a `\(value.type)` in a variable", line: line)
                }
                let name = try declareLocal(n.id, type: value.type, line: line)
                try store(code: name, type: value.type, value, line: line)
            }
            return
        }
        let lv = try lvalue(for: target, line: line)
        try store(code: lv.code, type: lv.type, value, line: line)
    }

    /// `code = value`, converted to `type`; a list element by element, as
    /// GLSL ES 1.00 cannot assign a whole array.
    func store(code: String, type: ShaderType, _ value: GLValue, line: Int) throws {
        if case .array(let element, let count) = type {
            guard case .array(_, let length) = value.type, length == count else {
                throw PyShaderError("cannot convert `\(value.type)` to `\(type)`", line: line)
            }
            let source = try materialize(value, line: line)
            guard case .array(let from, _) = source.type else { preconditionFailure() }
            for i in 0..<count {
                let v = try coerce(GLValue(code: "\(source.code)[\(i)]", type: from), to: element, line: line)
                self.line("\(code)[\(i)] = \(v.code);")
            }
            return
        }
        let v = try coerce(value, to: type, line: line)
        self.line("\(code) = \(v.code);")
    }

    /// An assignment target: a variable, a field, components, an element.
    func lvalue(for target: Expression, line: Int) throws -> (code: String, type: ShaderType) {
        switch target {
        case .name(let n):
            if counter(n.id) != nil {
                throw PyShaderError("OpenGL ES 2 loops may not change their counter `\(n.id)` (GLSL ES 1.00, Appendix A)", line: line)
            }
            if let local = locals[n.id] { return (local.name, local.type) }
            if declaredGlobals.contains(n.id), let v = try lookupVariable(n.id, line: line) { return (v.name, v.type) }
            if program.variables[n.id] != nil {
                throw PyShaderError("`\(n.id)` is a module variable; declare `global \(n.id)` to assign to it", line: line)
            }
            throw PyShaderError("`\(n.id)` is not defined", line: line)
        case .attribute(let a):
            guard isRooted(a.value) else {
                throw PyShaderError("can only assign to components of a variable (e.g. `color.rgb = ...`)", line: line)
            }
            let base = try lvalue(for: a.value, line: line)
            if case .structure(let name, let members) = base.type {
                guard let k = members.firstIndex(where: { $0.0 == a.attr }) else {
                    throw PyShaderError("`\(name)` has no field `\(a.attr)`", line: line)
                }
                return ("\(base.code).\(compiler.member(base.type, k))", members[k].1)
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
            guard Swift.Set(indices).count == indices.count else {
                throw PyShaderError("cannot assign to a swizzle with repeated components", line: line)
            }
            return ("\(base.code).\(Self.swizzleLetters(indices))", base.type.with(components: indices.count)!)
        case .subscriptExpr(let sub):
            guard isRooted(sub.value) else {
                throw PyShaderError("can only index into a variable", line: line)
            }
            let base = try lvalue(for: sub.value, line: line)
            if case .tuple = base.type {
                guard let k = constantIndex(sub.slice), let member = base.type.elementType(at: k < 0 ? k + base.type.count : k) else {
                    throw PyShaderError("tuple index must be a constant", line: line)
                }
                return ("\(base.code).m\(k < 0 ? k + base.type.count : k)", member)
            }
            guard let element = base.type.elementType(at: nil) else {
                throw PyShaderError("`\(base.type)` cannot be indexed", line: line)
            }
            let index = try emitIndex(sub.slice, count: base.type.count, line: line)
            return ("\(base.code)[\(index)]", element)
        default:
            throw PyShaderError("unsupported assignment target", line: line)
        }
    }

    /// Whether `e` is a variable or a field, element or component of one.
    private func isRooted(_ e: Expression) -> Bool {
        switch e {
        case .name: return true
        case .attribute(let a): return isRooted(a.value)
        case .subscriptExpr(let s): return isRooted(s.value)
        default: return false
        }
    }

    private func emitAnnAssign(_ a: AnnAssign) throws {
        guard case .name(let n) = a.target else {
            throw PyShaderError("only plain variables can be annotated", line: a.lineno)
        }
        if declaredGlobals.contains(n.id) {
            throw PyShaderError("`\(n.id)` is a module variable; it cannot be annotated here", line: a.lineno)
        }
        if counter(n.id) != nil {
            throw PyShaderError("OpenGL ES 2 loops may not change their counter `\(n.id)` (GLSL ES 1.00, Appendix A)", line: a.lineno)
        }
        var type = try program.resolveType(a.annotation, line: a.lineno)
        if case .array(let element, -1) = type {
            guard let valueExpr = a.value else {
                throw PyShaderError("`\(n.id)`: a list needs a value to fix its length", line: a.lineno)
            }
            let value = try emitExpression(valueExpr)
            guard case .array(_, let length) = value.type else {
                throw PyShaderError("`\(n.id)` is a list, got `\(value.type)`", line: a.lineno)
            }
            type = .array(element, length)
            let name: String
            if let existing = locals[n.id] {
                guard existing.type == type else {
                    throw PyShaderError("`\(n.id)` is already a `\(existing.type)`", line: a.lineno)
                }
                name = existing.name
            } else {
                name = try declareLocal(n.id, type: type, line: a.lineno)
            }
            try store(code: name, type: type, value, line: a.lineno)
            return
        }
        let name: String
        if let existing = locals[n.id] {
            guard existing.type == type else {
                throw PyShaderError("`\(n.id)` is already a `\(existing.type)`, cannot redeclare as `\(type)`", line: a.lineno)
            }
            name = existing.name
        } else {
            name = try declareLocal(n.id, type: type, line: a.lineno)
        }
        if let valueExpr = a.value {
            try store(code: name, type: type, try emitExpression(valueExpr), line: a.lineno)
        }
    }

    private func emitReturn(_ r: Return) throws {
        defer { falls = false }
        if returnType == .void {
            if let v = r.value, !isNoneLiteral(v) {
                throw PyShaderError("`\(functionName)` has no return type annotation, it cannot return a value", line: r.lineno)
            }
            line("return;")
            return
        }
        let value: GLValue
        if let expr = r.value, !isNoneLiteral(expr) {
            if case .tuple(let members) = returnType, case .tuple(let literal) = expr {
                guard literal.elts.count == members.count else {
                    throw PyShaderError("`\(functionName)` returns \(members.count) values, got \(literal.elts.count)", line: r.lineno)
                }
                var parts: [String] = []
                for (e, t) in zip(literal.elts, members) {
                    parts.append(try coerce(try emitExpression(e), to: t, line: r.lineno).code)
                }
                value = GLValue(code: "\(try typeName(returnType, line: r.lineno))(\(parts.joined(separator: ", ")))", type: returnType)
            } else {
                value = try coerce(try emitExpression(expr), to: returnType, line: r.lineno)
            }
        } else if let implicitReturn {
            value = try implicitReturn(self)
        } else {
            throw PyShaderError("`\(functionName)` must return a `\(returnType)`", line: r.lineno)
        }
        line("return \(value.code);")
    }

    private func isNoneLiteral(_ e: Expression) -> Bool {
        if case .constant(let c) = e, case .none = c.value { return true }
        return false
    }

    // MARK: Control flow

    func condition(_ expr: Expression, line: Int) throws -> GLValue {
        try truthy(try emitExpression(expr), line: line)
    }

    /// The statements of one branch, a level deeper; whether its end is reached.
    private func branch(_ statements: [Statement], entry: Bool) throws -> Bool {
        falls = entry
        indent += 1
        try emitBlock(statements)
        indent -= 1
        return falls
    }

    private func emitIf(_ i: If) throws {
        let entry = falls
        let cond = try condition(i.test, line: i.lineno)
        try emitIfChain(cond, i, entry: entry)
    }

    /// `if … else if … else`; an `elif` whose condition needs statements
    /// first is written as an `else` holding them and the next `if`.
    private func emitIfChain(_ cond: GLValue, _ i: If, entry: Bool) throws {
        let base = indent
        line("if (\(cond.code)) {")
        var reached = try branch(i.body, entry: entry)
        var orElse = i.orElse
        var hasElse = false
        while !orElse.isEmpty {
            if orElse.count == 1, case .ifStmt(let next) = orElse[0] {
                var nextCond = GLValue.void
                let prelude = try capture { nextCond = try condition(next.test, line: next.lineno) }
                if prelude.isEmpty {
                    line("} else if (\(nextCond.code)) {")
                } else {
                    line("} else {")
                    indent += 1
                    insert(prelude, shift: 1)
                    line("if (\(nextCond.code)) {")
                }
                reached = try branch(next.body, entry: entry) || reached
                orElse = next.orElse
            } else {
                line("} else {")
                reached = try branch(orElse, entry: entry) || reached
                hasElse = true
                orElse = []
            }
        }
        falls = hasElse ? reached : (reached || entry)
        while indent > base {
            line("}")
            indent -= 1
        }
        line("}")
    }

    /// `for i in range(…)`: GLSL ES 1.00 loops count with constants from a
    /// constant start to a constant stop, and the body never writes the counter.
    private func emitFor(_ f: For) throws {
        guard f.orElse.isEmpty else {
            throw PyShaderError("`for ... else` is not supported", line: f.lineno)
        }
        guard case .name(let target) = f.target else {
            throw PyShaderError("for-loop target must be a single variable", line: f.lineno)
        }
        var iter = f.iter
        if case .call(let hint) = iter, case .name(let h) = hint.fun, h.id == "unroll" || h.id == "dont_unroll" {
            guard hint.args.count == 1, hint.keywords.isEmpty else {
                throw PyShaderError("\(h.id)() wraps one `range(...)`", line: f.lineno)
            }
            iter = hint.args[0]   // GLSL ES 1.00 has no loop hints; the driver decides.
        }
        guard case .call(let call) = iter, case .name(let fn) = call.fun, fn.id == "range" else {
            throw PyShaderError("for-loops can only iterate `range(...)`", line: f.lineno)
        }
        guard call.keywords.isEmpty, (1...3).contains(call.args.count) else {
            throw PyShaderError("range() takes 1 to 3 positional arguments", line: f.lineno)
        }
        var bounds: [Int] = []
        for arg in call.args {
            let v = try emitExpression(arg)
            guard v.type.isScalar, v.type.isInt else {
                throw PyShaderError("range() arguments must be integers, got `\(v.type)`", line: f.lineno)
            }
            guard case .int(let k) = v.literal else {
                throw PyShaderError("OpenGL ES 2 loops need constant bounds (GLSL ES 1.00, Appendix A); this `range()` is computed at run time — loop to a constant maximum and `break`", line: f.lineno)
            }
            bounds.append(k)
        }
        let (start, stop, step): (Int, Int, Int)
        switch bounds.count {
        case 1: (start, stop, step) = (0, bounds[0], 1)
        case 2: (start, stop, step) = (bounds[0], bounds[1], 1)
        default: (start, stop, step) = (bounds[0], bounds[1], bounds[2])
        }
        guard step != 0 else { throw PyShaderError("range() step must not be zero", line: f.lineno) }
        if locals[target.id] != nil || declaredGlobals.contains(target.id) {
            throw PyShaderError("loop variable `\(target.id)` is already a variable; an OpenGL ES 2 loop counter lives only inside its loop, so give it a name of its own", line: f.lineno)
        }
        if counter(target.id) != nil {
            throw PyShaderError("loop variable `\(target.id)` is already the counter of an outer loop", line: f.lineno)
        }
        let name = localName(target.id)
        let condition = step > 0 ? "\(name) < \(stop)" : "\(name) > \(stop)"
        let advance = step == 1 ? "\(name)++" : step == -1 ? "\(name)--" : step > 0 ? "\(name) += \(step)" : "\(name) -= \(-step)"
        line("for (int \(name) = \(GLES2Writer.intLiteral(start)); \(condition); \(advance)) {")
        let entry = falls
        counters.append((target.id, name))
        loopDepth += 1
        _ = try branch(f.body, entry: entry)
        loopDepth -= 1
        counters.removeLast()
        finishedCounters.insert(target.id)
        line("}")
        falls = entry
    }

    /// `match` on an int, as an `if` chain (GLSL ES 1.00 has no `switch`).
    private func emitMatch(_ m: Match) throws {
        let subject = try emitExpression(m.subject)
        guard subject.type.isScalar, case .int = subject.type.scalarKind else {
            throw PyShaderError("match needs an int or uint subject, got `\(subject.type)`", line: m.lineno)
        }
        _ = try typeName(subject.type, line: m.lineno)
        let value = try materialize(subject, line: m.lineno)
        var defaultBody: [Statement]?
        var arms: [(test: String, body: [Statement])] = []
        var seen: Swift.Set<Int> = []
        for c in m.cases {
            let line = caseLine(c) ?? m.lineno
            if defaultBody != nil {
                throw PyShaderError("`case _` must be the last case; the ones after it can never match", line: line)
            }
            if c.guardExpr != nil {
                throw PyShaderError("a case guard (`case ... if ...`) is not supported; test the condition inside the case", line: line)
            }
            guard let literals = try caseLiterals(c.pattern, line: line) else {
                defaultBody = c.body
                continue
            }
            let fresh = literals.filter { seen.insert($0).inserted }
            guard !fresh.isEmpty else { continue }
            if let bad = fresh.first(where: { !(Int64(Int32.min)...Int64(Int32.max)).contains(Int64($0)) }) {
                throw PyShaderError("case \(bad) is out of range for a `\(subject.type)` subject", line: line)
            }
            let test = fresh.map { "\(value.code) == \(GLES2Writer.intLiteral($0))" }.joined(separator: " || ")
            arms.append((test, c.body))
        }
        let entry = falls
        var reached = defaultBody == nil && entry
        if arms.isEmpty {
            if let defaultBody {
                line("{")
                reached = try branch(defaultBody, entry: entry)
                line("}")
            }
            falls = reached
            return
        }
        for (index, arm) in arms.enumerated() {
            line(index == 0 ? "if (\(arm.test)) {" : "} else if (\(arm.test)) {")
            reached = try branch(arm.body, entry: entry) || reached
        }
        if let defaultBody {
            line("} else {")
            reached = try branch(defaultBody, entry: entry) || reached
        }
        line("}")
        falls = reached
    }

    private func caseLine(_ c: MatchCase) -> Int? {
        if case .matchValue(let v) = c.pattern {
            switch v.value {
            case .constant(let x): return x.lineno
            case .name(let x): return x.lineno
            case .binOp(let x): return x.lineno
            case .unaryOp(let x): return x.lineno
            default: break
            }
        }
        return c.body.first?.lineno
    }

    private func caseLiterals(_ pattern: Pattern, line: Int) throws -> [Int]? {
        switch pattern {
        case .matchAs(let a) where a.pattern == nil && (a.name == nil || a.name == "_"):
            return nil
        case .matchValue(let v):
            return try caseLiterals(v.value, line: line)
        case .matchOr(let o):
            return try o.patterns.flatMap { p -> [Int] in
                guard let values = try caseLiterals(p, line: line) else {
                    throw PyShaderError("`_` cannot be one of the alternatives in a case; make it a `case _:` of its own", line: line)
                }
                return values
            }
        default:
            throw PyShaderError("a case is int literals joined by `|`, or `_`", line: line)
        }
    }

    private func caseLiterals(_ e: Expression, line: Int) throws -> [Int] {
        if let k = constantIndex(e) { return [k] }
        switch e {
        case .binOp(let b) where b.op == .bitOr:
            return try caseLiterals(b.left, line: line) + caseLiterals(b.right, line: line)
        case .name(let n) where n.id == "_":
            throw PyShaderError("`_` cannot be one of the alternatives in a case; make it a `case _:` of its own", line: line)
        case .name(let n):
            throw PyShaderError("`case \(n.id):` would bind a new name, not compare against one; a case is int literals joined by `|`, or `_`", line: n.lineno)
        default:
            throw PyShaderError("a case is int literals joined by `|`, or `_`", line: line)
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

    /// The `discard;` statement; the rest of the block is dead.
    func emitDiscard() {
        line("discard;")
        falls = false
    }

    /// Whether `name` was a `for` counter, now out of scope.
    func wasCounter(_ name: String) -> Bool { finishedCounters.contains(name) }
}
