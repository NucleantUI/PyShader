//
//  ShaderProgram.swift
//  PyShader
//
//  First pass over the parsed module: validates the global scope and
//  collects function signatures, module constants and lambda templates so
//  code generation can resolve forward references.
//

import SpirvCore
import PySwiftAST

struct ShaderFunctionSignature {
    let name: String
    let params: [(name: String, type: ShaderType)]
    let returnType: ShaderType
    let def: FunctionDef
    var id: SpirvId = 0

}

struct LambdaTemplate {
    let name: String
    let lambda: Lambda
    let line: Int
}

final class ShaderProgram {
    let target: ShaderTarget
    /// The entry points the target compiles, by Python name — one for a
    /// single-stage target, `vertex` and `fragment` for `.graphics`.
    private(set) var entries: [String: EntrySignature]
    private(set) var functions: [String: ShaderFunctionSignature] = [:]
    private(set) var functionOrder: [String] = []
    /// Module-level constant expressions, inlined at each use site.
    private(set) var globals: [String: (expr: Expression, line: Int)] = [:]
    /// Module-level variables: globals some function declares `global` and
    /// assigns. Each is a `Private` variable, set from its initializer before
    /// the entry point runs. In declaration order, as they are initialized.
    private(set) var variables: [String: (expr: Expression, annotation: Expression?, line: Int)] = [:]
    private(set) var variableOrder: [String] = []
    private var annotations: [String: Expression] = [:]
    private(set) var lambdas: [String: LambdaTemplate] = [:]
    /// `class` declarations: plain structs of annotated fields.
    private(set) var structs: [String: ShaderType] = [:]

    init(module: Module, target: ShaderTarget) throws {
        self.target = target
        self.entries = try EntrySignature.all(for: target)
        // Classes first, so a function may return one declared below it;
        // then the vertex stage, whose varyings become the fragment stage's
        // parameters, before any other function.
        var defs: [FunctionDef] = []
        for stmt in module.body {
            if case .functionDef(let def) = stmt {
                defs.append(def)
            } else {
                try collect(stmt)
            }
        }
        if case .graphics(let i) = target, let vertex = defs.first(where: { $0.name == i.vertexEntryPoint }) {
            try declare(vertex)
            try addVaryings(from: vertex, to: i.fragmentEntryPoint, arguments: i.arguments.map(\.name))
        }
        for def in defs where functions[def.name] == nil {
            try declare(def)
        }
        try promoteVariables(defs)
        for entry in entries.values.sorted(by: { $0.entryPoint < $1.entryPoint }) where functions[entry.entryPoint] == nil {
            let returns = entry.outputType.map { "\($0)" } ?? "Varyings"
            throw PyShaderError("shader needs a global `def \(entry.entryPoint)(...) -> \(returns):` entry point")
        }
    }

    /// The single-stage entry point; the fragment one for `.graphics`.
    var entryPoint: String { target.entryPoint }

    func entry(named name: String) -> EntrySignature? { entries[name] }
    func isEntry(_ name: String) -> Bool { entries[name] != nil }

    /// Every member of the vertex stage's returned struct after the first
    /// (the position) is interpolated into the fragment stage, where it is
    /// taken by name like any other input. A varying may shadow a built-in
    /// input — `uv` is the natural name for a quad's own coordinate, and the
    /// screen's is still `frag_coord / resolution` — but not an argument,
    /// which is one value in both stages.
    private func addVaryings(from vertex: FunctionDef, to fragmentName: String, arguments: [String]) throws {
        let signature = functions[vertex.name]!
        guard case .structure(_, let members) = signature.returnType, let first = members.first else {
            throw PyShaderError("`\(vertex.name)` must return a class whose first field is the `float4` position", line: vertex.lineno)
        }
        guard first.1 == .float(4) else {
            throw PyShaderError("the first field of `\(vertex.name)`'s return class is the position and must be a `float4`, not `\(first.1)`", line: vertex.lineno)
        }
        guard var fragment = entries[fragmentName] else { return }
        for (name, type) in members.dropFirst() {
            if arguments.contains(name) {
                throw PyShaderError("varying `\(name)` clashes with the shader argument of the same name", line: vertex.lineno)
            }
            guard type.isScalar || type.isVector else {
                throw PyShaderError("varying `\(name)` must be a scalar or vector, not `\(type)`", line: vertex.lineno)
            }
            fragment.parameterTypes[name] = type
            fragment.parameterNames.removeAll { $0 == name }
            fragment.parameterNames.insert(name, at: 0)
        }
        entries[fragmentName] = fragment
    }

    private func collect(_ stmt: Statement) throws {
        switch stmt {
        case .functionDef(let def):
            try declare(def)
        case .assign(let a):
            guard a.targets.count == 1, case .name(let target) = a.targets[0] else {
                throw PyShaderError("module-level assignment must be `NAME = <constant expression>`", line: a.lineno)
            }
            try bindGlobal(name: target.id, value: a.value, line: a.lineno)
        case .annAssign(let a):
            guard case .name(let target) = a.target else {
                throw PyShaderError("module-level assignment must be `NAME = <constant expression>`", line: a.lineno)
            }
            guard let value = a.value else {
                throw PyShaderError("module-level declaration `\(target.id)` needs a value", line: a.lineno)
            }
            try bindGlobal(name: target.id, value: value, line: a.lineno)
            annotations[target.id] = a.annotation
        case .pass, .blank:
            break
        case .expr(let e):
            // Docstrings and bare constants are harmless.
            if case .constant = e.value { return }
            throw PyShaderError("module-level expressions are not allowed", line: e.lineno)
        case .importStmt(let imp):
            for alias in imp.names where !Self.isShaderModule(alias.name) {
                throw PyShaderError("cannot import `\(alias.name)`: shader code has no access to Python modules", line: imp.lineno)
            }
        case .importFrom(let imp):
            let module = imp.module ?? ""
            guard Self.isShaderModule(module) else {
                throw PyShaderError("cannot import from `\(module)`: shader code has no access to Python modules", line: imp.lineno)
            }
        case .classDef(let c):
            try declareStruct(c)
        case .asyncFunctionDef(let f):
            throw PyShaderError("async functions are not supported in shader code", line: f.lineno)
        default:
            throw PyShaderError("only functions and constants are allowed at module level", line: stmt.lineno)
        }
    }

    static func isShaderModule(_ name: String) -> Bool {
        name == "pyshader" || name.hasPrefix("pyshader.")
    }

    private func bindGlobal(name: String, value: Expression, line: Int) throws {
        if functions[name] != nil || globals[name] != nil || lambdas[name] != nil {
            throw PyShaderError("`\(name)` is already defined at module level", line: line)
        }
        if case .lambda(let l) = value {
            try Self.validateArguments(l.args, owner: "lambda `\(name)`", line: line)
            lambdas[name] = LambdaTemplate(name: name, lambda: l, line: line)
        } else {
            globals[name] = (value, line)
        }
    }

    /// A global a function declares `global` is assigned somewhere, so it is a
    /// variable rather than an inlined constant. Python's rule: without the
    /// declaration an assignment makes a local.
    private func promoteVariables(_ defs: [FunctionDef]) throws {
        func walk(_ statements: [Statement]) throws {
            for stmt in statements {
                switch stmt {
                case .global(let g):
                    for name in g.names {
                        if variables[name] != nil { continue }
                        guard let (expr, line) = globals[name] else {
                            if functions[name] != nil || lambdas[name] != nil {
                                throw PyShaderError("`\(name)` is a function, not a variable", line: g.lineno)
                            }
                            throw PyShaderError("`\(name)` is not assigned at module level", line: g.lineno)
                        }
                        globals[name] = nil
                        variables[name] = (expr, annotations[name], line)
                    }
                case .ifStmt(let i): try walk(i.body); try walk(i.orElse)
                case .whileStmt(let w): try walk(w.body); try walk(w.orElse)
                case .forStmt(let f): try walk(f.body); try walk(f.orElse)
                default: break
                }
            }
        }
        for def in defs { try walk(def.body) }
        variableOrder = variables.keys.sorted { variables[$0]!.line < variables[$1]!.line }
    }

    /// `class Name:` with one annotated field per line — a struct. No
    /// methods, bases, defaults or decorators: it is a shape, not behaviour.
    private func declareStruct(_ c: ClassDef) throws {
        if functions[c.name] != nil || globals[c.name] != nil || lambdas[c.name] != nil || structs[c.name] != nil {
            throw PyShaderError("`\(c.name)` is already defined at module level", line: c.lineno)
        }
        if ShaderType.named(c.name) != nil || c.name == "FloatArray" {
            throw PyShaderError("`\(c.name)` is a built-in type name", line: c.lineno)
        }
        if !c.bases.isEmpty || !c.keywords.isEmpty {
            throw PyShaderError("class `\(c.name)` cannot have base classes", line: c.lineno)
        }
        if !c.decoratorList.isEmpty {
            throw PyShaderError("decorators are not supported", line: c.lineno)
        }
        var members: [(String, ShaderType)] = []
        for stmt in c.body {
            switch stmt {
            case .annAssign(let a):
                guard case .name(let field) = a.target else {
                    throw PyShaderError("class `\(c.name)`: a field is `name: type`", line: a.lineno)
                }
                guard a.value == nil else {
                    throw PyShaderError("class `\(c.name)`: field `\(field.id)` cannot have a default value", line: a.lineno)
                }
                guard !members.contains(where: { $0.0 == field.id }) else {
                    throw PyShaderError("class `\(c.name)`: field `\(field.id)` is declared twice", line: a.lineno)
                }
                let type = try resolveType(a.annotation, line: a.lineno)
                guard type.isStorable else {
                    throw PyShaderError("class `\(c.name)`: field `\(field.id)` cannot be a `\(type)`", line: a.lineno)
                }
                members.append((field.id, type))
            case .pass, .blank:
                break
            case .expr(let e):
                if case .constant = e.value { continue }
                throw PyShaderError("class `\(c.name)` may only declare fields (`name: type`)", line: e.lineno)
            case .functionDef(let f):
                throw PyShaderError("class `\(c.name)`: methods are not supported; write `\(f.name)` as a module-level function", line: f.lineno)
            default:
                throw PyShaderError("class `\(c.name)` may only declare fields (`name: type`)", line: stmt.lineno)
            }
        }
        guard !members.isEmpty else {
            throw PyShaderError("class `\(c.name)` needs at least one field", line: c.lineno)
        }
        structs[c.name] = .structure(name: c.name, members: members)
    }

    private func declare(_ def: FunctionDef) throws {
        if functions[def.name] != nil || globals[def.name] != nil || lambdas[def.name] != nil || structs[def.name] != nil {
            throw PyShaderError("`\(def.name)` is already defined at module level", line: def.lineno)
        }
        if !def.decoratorList.isEmpty {
            throw PyShaderError("decorators are not supported", line: def.lineno)
        }
        try Self.validateArguments(def.args, owner: "`\(def.name)`", line: def.lineno)

        let entry = entries[def.name]
        var params: [(String, ShaderType)] = []
        for arg in def.args.posonlyArgs + def.args.args {
            if let entry {
                guard let type = entry.parameterTypes[arg.arg] else {
                    let names = entry.parameterNames.joined(separator: ", ")
                    throw PyShaderError("`\(def.name)` parameter `\(arg.arg)` is not a shader input; available: \(names)", line: def.lineno)
                }
                if let ann = arg.annotation {
                    let declared = try resolveType(ann, line: def.lineno)
                    guard declared == type || (declared == .floatArray(argument: -1) && type.isFloatArray) else {
                        throw PyShaderError("`\(arg.arg)` is a `\(type)` input, not `\(declared)`", line: def.lineno)
                    }
                }
                params.append((arg.arg, type))
            } else {
                guard let ann = arg.annotation else {
                    throw PyShaderError("parameter `\(arg.arg)` of `\(def.name)` needs a type annotation", line: def.lineno)
                }
                params.append((arg.arg, try resolveType(ann, line: def.lineno)))
            }
        }

        let returnType: ShaderType
        if let r = def.returns {
            if case .constant(let c) = r, case .none = c.value {
                returnType = .void
            } else {
                returnType = try resolveType(r, line: def.lineno)
            }
        } else {
            returnType = entry?.outputType ?? .void
        }
        if let entry {
            if let expected = entry.outputType {
                if returnType != expected {
                    throw PyShaderError("`\(def.name)` must return `\(expected)` (the pixel color)", line: def.lineno)
                }
            } else if case .structure = returnType {
                // A vertex stage: checked by `addVaryings`.
            } else {
                throw PyShaderError("`\(def.name)` must return a class whose first field is the `float4` position", line: def.lineno)
            }
        }

        functions[def.name] = ShaderFunctionSignature(name: def.name, params: params, returnType: returnType, def: def)
        functionOrder.append(def.name)
    }

    func assignFunctionId(_ name: String, _ id: SpirvId) {
        functions[name]?.id = id
    }

    static func validateArguments(_ args: Arguments, owner: String, line: Int) throws {
        if args.vararg != nil || args.kwarg != nil {
            throw PyShaderError("\(owner): *args / **kwargs are not supported", line: line)
        }
        if !args.kwonlyArgs.isEmpty {
            throw PyShaderError("\(owner): keyword-only parameters are not supported", line: line)
        }
        if !args.defaults.isEmpty {
            throw PyShaderError("\(owner): default parameter values are not supported", line: line)
        }
    }

    /// Resolves a type annotation expression (`float3`, `pyshader.float3`, a
    /// `class` declared in the module) to a shader type.
    func resolveType(_ expr: Expression, line: Int) throws -> ShaderType {
        if case .name(let n) = expr, let s = structs[n.id] { return s }
        return try Self.resolveType(expr, line: line)
    }

    /// Resolves a built-in type annotation (`float3`, `pyshader.float3`, `tuple[...]`).
    static func resolveType(_ expr: Expression, line: Int) throws -> ShaderType {
        switch expr {
        case .name(let n):
            if let t = ShaderType.named(n.id) { return t }
            if n.id == "FloatArray" { return .floatArray(argument: -1) }
            throw PyShaderError("unknown type `\(n.id)`", line: line)
        case .attribute(let a):
            if let t = ShaderType.named(a.attr) { return t }
            if a.attr == "FloatArray" { return .floatArray(argument: -1) }
            throw PyShaderError("unknown type `\(a.attr)`", line: line)
        case .constant(let c):
            if case .string(let s) = c.value, let t = ShaderType.named(s) { return t }
            throw PyShaderError("unsupported type annotation", line: line)
        case .subscriptExpr(let sub):
            // tuple[float, float3] / list[float4]
            guard case .name(let generic) = sub.value else {
                throw PyShaderError("unsupported type annotation", line: line)
            }
            switch generic.id {
            case "tuple":
                let elements: [Expression]
                if case .tuple(let t) = sub.slice { elements = t.elts } else { elements = [sub.slice] }
                return .tuple(try elements.map { try resolveType($0, line: line) })
            case "list":
                // The length comes from the value; -1 marks "any length" until then.
                return .array(try resolveType(sub.slice, line: line), -1)
            default:
                throw PyShaderError("unknown generic type `\(generic.id)`; use tuple[...] or list[...]", line: line)
            }
        default:
            throw PyShaderError("unsupported type annotation", line: line)
        }
    }
}
