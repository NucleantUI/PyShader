//
//  ModuleDecompiler.swift
//  Spirv2PyShader
//
//  Drives one module: analysis, one `FunctionDecompiler` per reachable
//  function, the peephole passes over each body, and the final text.
//

import PyShader
import SpirvCore

final class ModuleDecompiler {
    let module: ModuleIndex
    let analysis: ModuleAnalysis
    let options: DecompileOptions
    private(set) var warnings: [String] = []
    let userFunctionNames: Set<String>

    init(module: ModuleIndex, interface: FragmentInterface, options: DecompileOptions) throws {
        self.module = module
        self.options = options
        let map = InterfaceMap(module: module, interface: interface, options: options)
        analysis = try ModuleAnalysis(module: module, interface: map, options: options)
        userFunctionNames = Set(analysis.functionNames.values)
        warnings += map.takeWarnings()
    }

    func warn(_ message: String) {
        if !warnings.contains(message) { warnings.append(message) }
    }

    func decompile() throws -> DecompiledShader {
        var functions: [PyFunction] = []
        let globalNames = analysis.interface.privateOrder.map { analysis.interface.privateGlobals[$0]! }
        let globalTypes = Dictionary(uniqueKeysWithValues: analysis.interface.privateOrder.map { (analysis.interface.privateGlobals[$0]!, module.globals[$0]!.type) })
        for id in analysis.order {
            guard let fn = module.function(id) else { continue }
            var py = try FunctionDecompiler(ctx: self, function: fn).decompile()
            py.body = Peepholes.run(py.body, locals: py.localTypes, params: Set(py.params.map(\.name)), globals: globalTypes, typeName: analysis.typeName)
            functions.append(py)
        }
        var initializers = try foldGlobalsInit(&functions, globals: Set(globalNames))
        for i in functions.indices {
            let written = functions[i].body.writtenNames
            functions[i].globals = globalNames.filter { written.contains($0) }
        }
        functions = Peepholes.collapseWrapper(functions)

        var text = "from pyshader import *\n"
        if options.header {
            text = "# Decompiled from SPIR-V (\(module.generatorDescription)) by spirv2py.\n" + text
        }
        for s in analysis.structs {
            guard case .structure(_, let members) = s else { continue }
            text += "\n\nclass \(analysis.typeName(s)):\n"
            for (name, type) in members {
                text += "    \(name): \(analysis.typeName(type))\n"
            }
        }
        if !globalNames.isEmpty { text += "\n" }
        for id in analysis.interface.privateOrder {
            let g = module.globals[id]!
            let name = analysis.interface.privateGlobals[id]!
            let value = try initializers.removeValue(forKey: name)
                ?? g.initializer.flatMap { module.constants[$0] }.map { try render(constant: $0) }
                ?? zero(of: g.type)
            text += "\n\(name) = \(value.rendered)"
        }
        if !globalNames.isEmpty { text += "\n" }
        for f in functions {
            text += "\n\n" + f.rendered + "\n"
        }
        let entry = functions.last(where: \.isEntry)?.name ?? analysis.entryName
        return DecompiledShader(source: text, warnings: warnings, entryPoint: entry)
    }

    // MARK: - PyShader's `py_globals`

    /// Module variables initialized at the start of the entry point are
    /// initialized at module level instead, where the source had them.
    /// glslang stores a global's initializer in `main` when it is not a plain
    /// constant; only ones that read nothing move. PyShader sets its module
    /// variables in a `py_globals` function every entry wrapper calls first;
    /// those assignments are the module-level values again and the function
    /// and its calls go.
    private func foldGlobalsInit(_ functions: inout [PyFunction], globals: Set<String>) throws -> [String: PyExpr] {
        var values: [String: PyExpr] = [:]
        if let id = analysis.order.first(where: { module.names[$0] == "py_globals" }),
           let index = functions.firstIndex(where: { $0.name == analysis.name(of: id) }),
           functions[index].body.allSatisfy({ s in
               if case .assign(.name(let g), _) = s { return globals.contains(g) }
               if case .ret(nil) = s { return true }
               return false
           }) {
            let name = functions[index].name
            for case .assign(.name(let g), let e) in functions[index].body where values[g] == nil { values[g] = e }
            functions.remove(at: index)
            for i in functions.indices {
                functions[i].body.removeAll { s in
                    if case .expr(.call(name, let args)) = s, args.isEmpty { return true }
                    return false
                }
            }
        }
        if let entry = functions.firstIndex(where: \.isEntry) {
            while case .assign(.name(let g), let e)? = functions[entry].body.first,
                  globals.contains(g), values[g] == nil, isConstant(e) {
                values[g] = e
                functions[entry].body.removeFirst()
            }
        }
        return values
    }

    /// Reads no variable and calls only constructors and builtins.
    private func isConstant(_ e: PyExpr) -> Bool {
        if case .name = e { return false }
        if case .call(let f, _) = e, ShaderType.named(f) == nil, !PyNames.builtins.contains(f) || f == "discard" { return false }
        return e.children.allSatisfy(isConstant)
    }

    // MARK: - Constants

    func render(constant c: Constant) throws -> PyExpr {
        switch c.value {
        case .bool(let b):
            return .bool(b)
        case .int(let v):
            return intLiteral(v, type: c.type)
        case .float(let d):
            return floatLiteral(d, type: c.type)
        case .composite(let ids):
            let elts = try ids.map { id -> PyExpr in
                guard let inner = module.constants[id] else { throw Spirv2PyShaderError("constant %\(id) is missing") }
                return try render(constant: inner)
            }
            return composite(c.type, elts)
        case .null:
            return zero(of: c.type)
        case .undefined:
            warn("OpUndef written as zero")
            return zero(of: c.type)
        }
    }

    func intLiteral(_ v: Int64, type: ShaderType) -> PyExpr {
        guard case .scalar(.int(let bits, let signed)) = type else { return .number("\(v)") }
        if bits == 32, signed { return .number("\(v)") }
        return .call(type.description, [.number("\(v)")])
    }

    func floatLiteral(_ d: Double, type: ShaderType) -> PyExpr {
        let f = Float(d)
        var text: String
        if f.isNaN {
            warn("a NaN constant")
            text = "float(\"nan\")"
        } else if f.isInfinite {
            warn("an infinite constant")
            text = f < 0 ? "-float(\"inf\")" : "float(\"inf\")"
        } else {
            text = f.description
            if !text.contains(".") && !text.contains("e") { text += ".0" }
        }
        if case .scalar(.float(16)) = type { return .call("half", [.number(text)]) }
        return .number(text)
    }

    private func composite(_ t: ShaderType, _ elts: [PyExpr]) -> PyExpr {
        switch t {
        case .vector:
            if elts.count > 1, elts.allSatisfy({ $0 == elts[0] }) { return .call(t.description, [elts[0]]) }
            return .call(t.description, elts)
        case .matrix:
            return .call(t.description, elts)
        case .array(_, let n):
            if n > 1, elts.allSatisfy({ $0 == elts[0] }) { return .binary("*", .list([elts[0]]), .number("\(n)")) }
            return .list(elts)
        case .tuple:
            return .tuple(elts)
        case .structure:
            return .call(analysis.typeName(t), elts)
        default:
            return .tuple(elts)
        }
    }

    /// Zero of any type, for `OpConstantNull` and uninitialised lists.
    func zero(of t: ShaderType) -> PyExpr {
        switch t {
        case .scalar(.bool): return .bool(false)
        case .scalar(.float): return floatLiteral(0, type: t)
        case .scalar(.int): return intLiteral(0, type: t)
        case .vector(let k, _): return .call(t.description, [zero(of: .scalar(k))])
        case .matrix: return .call(t.description, [.number("0.0")])
        case .array(let e, let n): return .binary("*", .list([zero(of: e)]), .number("\(n)"))
        case .tuple(let ts): return .tuple(ts.map(zero))
        case .structure(_, let members): return .call(analysis.typeName(t), members.map { zero(of: $0.1) })
        default: return .number("0")
        }
    }
}
