//
//  ShaderProgram.swift
//  PyShader
//
//  First pass over the parsed module: validates the global scope and
//  collects function signatures, module constants and lambda templates so
//  code generation can resolve forward references.
//

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
    let entry: EntrySignature
    private(set) var functions: [String: ShaderFunctionSignature] = [:]
    private(set) var functionOrder: [String] = []
    /// Module-level constant expressions, inlined at each use site.
    private(set) var globals: [String: (expr: Expression, line: Int)] = [:]
    private(set) var lambdas: [String: LambdaTemplate] = [:]

    init(module: Module, target: ShaderTarget) throws {
        self.target = target
        self.entry = try EntrySignature(target)
        for stmt in module.body {
            try collect(stmt)
        }
        guard functions[entry.entryPoint] != nil else {
            throw PyShaderError("shader needs a global `def \(entry.entryPoint)(...) -> float4:` entry point")
        }
    }

    var entryPoint: String { entry.entryPoint }

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
            throw PyShaderError("classes are not supported in shader code yet", line: c.lineno)
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

    private func declare(_ def: FunctionDef) throws {
        if functions[def.name] != nil || globals[def.name] != nil || lambdas[def.name] != nil {
            throw PyShaderError("`\(def.name)` is already defined at module level", line: def.lineno)
        }
        if !def.decoratorList.isEmpty {
            throw PyShaderError("decorators are not supported", line: def.lineno)
        }
        try Self.validateArguments(def.args, owner: "`\(def.name)`", line: def.lineno)

        let isEntry = def.name == entry.entryPoint
        var params: [(String, ShaderType)] = []
        for arg in def.args.posonlyArgs + def.args.args {
            if isEntry {
                guard let type = entry.parameterTypes[arg.arg] else {
                    let names = entry.parameterNames.joined(separator: ", ")
                    throw PyShaderError("`\(def.name)` parameter `\(arg.arg)` is not a shader input; available: \(names)", line: def.lineno)
                }
                if let ann = arg.annotation {
                    let declared = try Self.resolveType(ann, line: def.lineno)
                    guard declared == type || (declared == .floatArray(argument: -1) && type.isFloatArray) else {
                        throw PyShaderError("`\(arg.arg)` is a `\(type)` input, not `\(declared)`", line: def.lineno)
                    }
                }
                params.append((arg.arg, type))
            } else {
                guard let ann = arg.annotation else {
                    throw PyShaderError("parameter `\(arg.arg)` of `\(def.name)` needs a type annotation", line: def.lineno)
                }
                params.append((arg.arg, try Self.resolveType(ann, line: def.lineno)))
            }
        }

        let returnType: ShaderType
        if let r = def.returns {
            if case .constant(let c) = r, case .none = c.value {
                returnType = .void
            } else {
                returnType = try Self.resolveType(r, line: def.lineno)
            }
        } else {
            returnType = isEntry ? entry.outputType : .void
        }
        if isEntry && returnType != entry.outputType {
            throw PyShaderError("`\(def.name)` must return `\(entry.outputType)` (the pixel color)", line: def.lineno)
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

    /// Resolves a type annotation expression (`float3`, `pyshader.float3`) to a shader type.
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
        default:
            throw PyShaderError("unsupported type annotation", line: line)
        }
    }
}
