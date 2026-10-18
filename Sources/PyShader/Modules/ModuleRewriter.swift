//
//  ModuleRewriter.swift
//  PyShader
//
//  Renames, in one top-level statement of one module, every global name
//  that resolves to another module's definition to that definition's
//  qualified name, pulling the definition in. Python's scoping decides what
//  is global: inside a function, its parameters and every name it assigns
//  (without declaring it `global`) are its own and stay as they are.
//

import PySwiftAST

struct ModuleRewriter {
    let linker: ModuleLinker
    let module: ModuleLinker.LoadedModule

    /// A top-level statement, its defined name changed to `renamedTo` when given.
    func topLevel(_ stmt: Statement, renamedTo newName: String?) throws -> Statement {
        switch stmt {
        case .functionDef(var d):
            if let newName { d.name = newName }
            d.decoratorList = try d.decoratorList.map { try expr($0, []) }
            if let r = d.returns { d.returns = try expr(r, []) }
            d.args = try annotations(d.args)
            let locals = Self.parameters(d.args).union(Self.assigned(d.body)).subtracting(Self.declaredGlobal(d.body))
            d.body = try block(d.body, locals)
            return .functionDef(d)
        case .classDef(var c):
            if let newName { c.name = newName }
            c.body = try c.body.map { field in
                guard case .annAssign(var a) = field else { return field }
                a.annotation = try expr(a.annotation, [])
                return .annAssign(a)
            }
            return .classDef(c)
        case .assign(var a):
            if let newName, case .name(var n) = a.targets[0] {
                n.id = newName
                a.targets[0] = .name(n)
            }
            a.value = try expr(a.value, [])
            return .assign(a)
        case .annAssign(var a):
            if let newName, case .name(var n) = a.target {
                n.id = newName
                a.target = .name(n)
            }
            a.annotation = try expr(a.annotation, [])
            if let v = a.value { a.value = try expr(v, []) }
            return .annAssign(a)
        default:
            // Anything else at the shader's top level is ShaderProgram's to judge.
            return stmt
        }
    }

    // MARK: - Names

    /// The name a global `name` goes by in the linked shader; nil to keep it.
    private func global(_ name: String, line: Int) throws -> String? {
        guard let binding = try linker.resolve(name, in: module, line: line) else { return nil }
        switch binding {
        case .symbol(let m, let n):
            return try linker.include(m, n)
        case .module(let d):
            throw PyShaderError("`\(name)` is the module `\(d.name)`, not a value; use one of its names (`\(name).<name>`)", line: line)
        }
    }

    /// `noise.fbm`, `shaderlib.noise.fbm`, `n.PI.x`: when the chain starts at a
    /// module, the part naming a definition becomes that definition's name.
    private func moduleChain(_ a: Attribute, _ locals: Swift.Set<String>) throws -> Expression? {
        var attributes: [Attribute] = []
        var base = Expression.attribute(a)
        while case .attribute(let x) = base {
            attributes.insert(x, at: 0)
            base = x.value
        }
        guard case .name(let n) = base, !locals.contains(n.id),
              case .module(var d)? = try linker.resolve(n.id, in: module, line: n.lineno) else { return nil }
        for (i, x) in attributes.enumerated() {
            switch try linker.resolveMember(d, x.attr, line: x.lineno, in: module) {
            case .module(let sub):
                d = sub
            case .symbol(let m, let name):
                var result = Expression.name(Name(id: try linker.include(m, name), ctx: x.ctx, lineno: x.lineno, colOffset: x.colOffset))
                for var rest in attributes[(i + 1)...] {
                    rest.value = result
                    result = .attribute(rest)
                }
                return result
            }
        }
        throw PyShaderError("`\(d.name)` is a module, not a value; use one of its names", line: a.lineno)
    }

    // MARK: - Expressions

    private func expr(_ e: Expression, _ locals: Swift.Set<String>) throws -> Expression {
        func sub(_ e: Expression) throws -> Expression { try expr(e, locals) }
        switch e {
        case .name(var n):
            if !locals.contains(n.id), let renamed = try global(n.id, line: n.lineno) { n.id = renamed }
            return .name(n)
        case .attribute(var a):
            if let chain = try moduleChain(a, locals) { return chain }
            a.value = try sub(a.value)
            return .attribute(a)
        case .call(var c):
            c.fun = try sub(c.fun)
            c.args = try c.args.map(sub)
            c.keywords = try c.keywords.map { k in var k = k; k.value = try sub(k.value); return k }
            return .call(c)
        case .binOp(var b):
            b.left = try sub(b.left)
            b.right = try sub(b.right)
            return .binOp(b)
        case .unaryOp(var u):
            u.operand = try sub(u.operand)
            return .unaryOp(u)
        case .boolOp(var b):
            b.values = try b.values.map(sub)
            return .boolOp(b)
        case .compare(var c):
            c.left = try sub(c.left)
            c.comparators = try c.comparators.map(sub)
            return .compare(c)
        case .ifExp(var i):
            i.test = try sub(i.test)
            i.body = try sub(i.body)
            i.orElse = try sub(i.orElse)
            return .ifExp(i)
        case .subscriptExpr(var s):
            s.value = try sub(s.value)
            s.slice = try sub(s.slice)
            return .subscriptExpr(s)
        case .slice(var s):
            if let x = s.lower { s.lower = try sub(x) }
            if let x = s.upper { s.upper = try sub(x) }
            if let x = s.step { s.step = try sub(x) }
            return .slice(s)
        case .tuple(var t):
            t.elts = try t.elts.map(sub)
            return .tuple(t)
        case .list(var l):
            l.elts = try l.elts.map(sub)
            return .list(l)
        case .starred(var s):
            s.value = try sub(s.value)
            return .starred(s)
        case .lambda(var l):
            l.body = try expr(l.body, locals.union(Self.parameters(l.args)))
            return .lambda(l)
        default:
            // Constants, and what shader code rejects anyway (strings, dicts, comprehensions, ...).
            return e
        }
    }

    private func annotations(_ args: Arguments) throws -> Arguments {
        var args = args
        func annotate(_ a: Arg) throws -> Arg {
            var a = a
            if let ann = a.annotation { a.annotation = try expr(ann, []) }
            return a
        }
        args.posonlyArgs = try args.posonlyArgs.map(annotate)
        args.args = try args.args.map(annotate)
        args.kwonlyArgs = try args.kwonlyArgs.map(annotate)
        return args
    }

    // MARK: - Statements

    private func block(_ statements: [Statement], _ locals: Swift.Set<String>) throws -> [Statement] {
        try statements.map { try statement($0, locals) }
    }

    private func statement(_ stmt: Statement, _ locals: Swift.Set<String>) throws -> Statement {
        func sub(_ e: Expression) throws -> Expression { try expr(e, locals) }
        switch stmt {
        case .assign(var a):
            a.targets = try a.targets.map(sub)
            a.value = try sub(a.value)
            return .assign(a)
        case .augAssign(var a):
            a.target = try sub(a.target)
            a.value = try sub(a.value)
            return .augAssign(a)
        case .annAssign(var a):
            a.target = try sub(a.target)
            a.annotation = try sub(a.annotation)
            if let v = a.value { a.value = try sub(v) }
            return .annAssign(a)
        case .returnStmt(var r):
            if let v = r.value { r.value = try sub(v) }
            return .returnStmt(r)
        case .expr(var e):
            e.value = try sub(e.value)
            return .expr(e)
        case .ifStmt(var i):
            i.test = try sub(i.test)
            i.body = try block(i.body, locals)
            i.orElse = try block(i.orElse, locals)
            return .ifStmt(i)
        case .whileStmt(var w):
            w.test = try sub(w.test)
            w.body = try block(w.body, locals)
            w.orElse = try block(w.orElse, locals)
            return .whileStmt(w)
        case .forStmt(var f):
            f.target = try sub(f.target)
            f.iter = try sub(f.iter)
            f.body = try block(f.body, locals)
            f.orElse = try block(f.orElse, locals)
            return .forStmt(f)
        case .match(var m):
            m.subject = try sub(m.subject)
            m.cases = try m.cases.map { c in
                var c = c
                c.pattern = try pattern(c.pattern, locals)
                if let g = c.guardExpr { c.guardExpr = try sub(g) }
                c.body = try block(c.body, locals)
                return c
            }
            return .match(m)
        case .global(var g):
            g.names = try g.names.map { try global($0, line: g.lineno) ?? $0 }
            return .global(g)
        default:
            // Nested functions, imports in a function, ...: FunctionEmitter reports them.
            return stmt
        }
    }

    private func pattern(_ p: Pattern, _ locals: Swift.Set<String>) throws -> Pattern {
        switch p {
        case .matchValue(var v):
            v.value = try expr(v.value, locals)
            return .matchValue(v)
        case .matchClass(var c):
            c.cls = try expr(c.cls, locals)
            c.patterns = try c.patterns.map { try pattern($0, locals) }
            c.kwdPatterns = try c.kwdPatterns.map { try pattern($0, locals) }
            return .matchClass(c)
        case .matchSequence(var s):
            s.patterns = try s.patterns.map { try pattern($0, locals) }
            return .matchSequence(s)
        case .matchOr(var o):
            o.patterns = try o.patterns.map { try pattern($0, locals) }
            return .matchOr(o)
        case .matchAs(var a):
            if let inner = a.pattern { a.pattern = try pattern(inner, locals) }
            return .matchAs(a)
        case .matchMapping(var m):
            m.keys = try m.keys.map { try expr($0, locals) }
            m.patterns = try m.patterns.map { try pattern($0, locals) }
            return .matchMapping(m)
        default:
            return p
        }
    }

    // MARK: - Scopes

    static func parameters(_ args: Arguments) -> Swift.Set<String> {
        var names = Swift.Set((args.posonlyArgs + args.args + args.kwonlyArgs).map(\.arg))
        if let v = args.vararg { names.insert(v.arg) }
        if let k = args.kwarg { names.insert(k.arg) }
        return names
    }

    /// The names a function body binds — Python makes each of them local to
    /// the whole function unless it is declared `global`.
    static func assigned(_ statements: [Statement]) -> Swift.Set<String> {
        var names: Swift.Set<String> = []
        func targets(_ e: Expression) {
            switch e {
            case .name(let n): names.insert(n.id)
            case .tuple(let t): t.elts.forEach(targets)
            case .list(let l): l.elts.forEach(targets)
            case .starred(let s): targets(s.value)
            default: break
            }
        }
        func captures(_ p: Pattern) {
            switch p {
            case .matchAs(let a):
                if let name = a.name { names.insert(name) }
                if let inner = a.pattern { captures(inner) }
            case .matchStar(let s):
                if let name = s.name { names.insert(name) }
            case .matchSequence(let s): s.patterns.forEach(captures)
            case .matchOr(let o): o.patterns.forEach(captures)
            case .matchClass(let c): (c.patterns + c.kwdPatterns).forEach(captures)
            case .matchMapping(let m):
                m.patterns.forEach(captures)
                if let rest = m.rest { names.insert(rest) }
            default: break
            }
        }
        func walk(_ statements: [Statement]) {
            for stmt in statements {
                switch stmt {
                case .assign(let a): a.targets.forEach(targets)
                case .augAssign(let a): targets(a.target)
                case .annAssign(let a): targets(a.target)
                case .forStmt(let f): targets(f.target); walk(f.body); walk(f.orElse)
                case .whileStmt(let w): walk(w.body); walk(w.orElse)
                case .ifStmt(let i): walk(i.body); walk(i.orElse)
                case .match(let m):
                    for c in m.cases { captures(c.pattern); walk(c.body) }
                case .functionDef(let d): names.insert(d.name)
                case .classDef(let c): names.insert(c.name)
                default: break
                }
            }
        }
        walk(statements)
        return names
    }

    static func declaredGlobal(_ statements: [Statement]) -> Swift.Set<String> {
        var names: Swift.Set<String> = []
        func walk(_ statements: [Statement]) {
            for stmt in statements {
                switch stmt {
                case .global(let g): names.formUnion(g.names)
                case .forStmt(let f): walk(f.body); walk(f.orElse)
                case .whileStmt(let w): walk(w.body); walk(w.orElse)
                case .ifStmt(let i): walk(i.body); walk(i.orElse)
                case .match(let m): m.cases.forEach { walk($0.body) }
                default: break
                }
            }
        }
        walk(statements)
        return names
    }
}
