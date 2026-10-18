//
//  ModuleLinker.swift
//  PyShader
//
//  Resolves a shader's imports of other PyShader modules and pulls the
//  definitions it uses into the shader, as if they were written there.
//
//  Every module an import names is found (`ShaderModules`), parsed and
//  scanned for its top-level definitions and imports. Then the shader is
//  walked: a name that resolves to another module's definition — directly
//  (`from noise import fbm`), through the module (`noise.fbm`), through a
//  wildcard (`from noise import *`) or re-exported along a chain of modules —
//  is renamed to that definition's qualified name, `noise.fbm`, and the
//  definition joins the shader, itself walked the same way in its own
//  module. Only what is reached that way is included; a `*` brings in no
//  more than the names the code uses. Qualified names contain a `.`, so they
//  never clash with the shader's own names or another module's.
//

import PySwiftAST

final class ModuleLinker {
    /// A parsed module: what it defines at the top level and what its imports bind.
    final class LoadedModule {
        /// Dotted name; "" for the shader being compiled.
        let name: String
        /// For errors and `OpString`; nil for the shader being compiled.
        let file: String?
        let isPackage: Bool
        /// `def`, `class` and `NAME = ...` at the top level, by name.
        var definitions: [String: Statement] = [:]
        /// Names bound by `import` / `from ... import`.
        var bindings: [String: ImportBinding] = [:]
        /// `from x import *`, by module name.
        var stars: [(module: String, line: Int)] = []
        /// `__all__`: the names `*` exports, when declared.
        var exports: [String]?

        init(name: String, file: String?, isPackage: Bool) {
            self.name = name
            self.file = file
            self.isPackage = isPackage
        }

        var isMain: Bool { name.isEmpty }
    }

    enum ImportBinding {
        /// `import a.b` binds `a` to the module `a`; `import a.b as c` binds `c` to `a.b`.
        case module(String)
        /// `from a import x`: whatever `x` is in `a` (a definition, another import, a submodule).
        case member(module: String, name: String, line: Int)
    }

    enum Binding {
        case symbol(LoadedModule, String)
        case module(LoadedModule)
    }

    let modules: ShaderModules
    private var loaded: [String: LoadedModule] = [:]
    private var loadOrder: [String] = []
    /// Definitions pulled in so far, by qualified name (and ones being pulled in).
    private var included: Swift.Set<String> = []
    private var output: [Statement] = []
    /// Qualified name -> the file it came from.
    private(set) var origins: [String: String] = [:]
    private var resolving: Swift.Set<String> = []

    init(modules: ShaderModules) {
        self.modules = modules
    }

    /// The shader with every definition it uses from other modules added
    /// before its own statements and its module imports removed. A shader
    /// that imports nothing besides `pyshader` comes back as it is.
    func link(_ module: Module) throws -> Module {
        let body = module.body
        guard body.contains(where: Self.importsOtherModule) else { return module }

        let main = LoadedModule(name: "", file: nil, isPackage: false)
        try scan(main, body)
        try validateImports(main)
        var i = 0
        while i < loadOrder.count {
            let m = loaded[loadOrder[i]]!
            try PyShaderError.attributing(to: m.file) { try validateImports(m) }
            i += 1
        }

        let rewriter = ModuleRewriter(linker: self, module: main)
        for stmt in body {
            switch stmt {
            case .importStmt, .importFrom:
                if Self.importsOtherModule(stmt) { continue }
                output.append(stmt)
            default:
                // Rewritten first: what it pulls in goes ahead of it.
                let rewritten = try rewriter.topLevel(stmt, renamedTo: nil)
                output.append(rewritten)
            }
        }
        return .module(output)
    }

    /// An import of something other than `pyshader`.
    private static func importsOtherModule(_ stmt: Statement) -> Bool {
        switch stmt {
        case .importStmt(let i): return i.names.contains { !ShaderProgram.isShaderModule($0.name) }
        case .importFrom(let i): return i.level > 0 || !ShaderProgram.isShaderModule(i.module ?? "")
        default: return false
        }
    }

    // MARK: - Loading

    /// Finds, parses and scans `name` and the packages above it.
    @discardableResult
    private func load(_ name: String, line: Int, from importer: LoadedModule) throws -> LoadedModule {
        guard let module = try loadIfPresent(name, line: line, from: importer) else {
            throw PyShaderError("cannot import `\(name)`: no PyShader module named `\(name)` (shader code can import `pyshader` and PyShader modules only)", line: line)
        }
        return module
    }

    private func loadIfPresent(_ name: String, line: Int, from importer: LoadedModule) throws -> LoadedModule? {
        if let m = loaded[name] { return m }
        let parts = name.split(separator: ".")
        if parts.count > 1 {
            let parent = parts.dropLast().joined(separator: ".")
            guard let p = try loadIfPresent(parent, line: line, from: importer), p.isPackage else { return nil }
        }
        switch modules.locate(name) {
        case .missing:
            return nil
        case .notShaderModule(let file):
            throw PyShaderError("cannot import `\(name)`: `\(file)` is installed but is not a PyShader module (its package declares no `pyshader.modules` entry point)", line: line)
        case .found(let located):
            let module = LoadedModule(name: name, file: located.file, isPackage: located.isPackage)
            loaded[name] = module
            loadOrder.append(name)
            let parsed = try PyShaderError.attributing(to: located.file) {
                try PyShader.parse(located.source)
            }
            try PyShaderError.attributing(to: located.file) { try scan(module, parsed.body) }
            return module
        }
    }

    /// Records the top-level definitions, then loads what the imports name.
    /// The shader's own other statements are left to `ShaderProgram`; a
    /// module may only define and import.
    private func scan(_ m: LoadedModule, _ body: [Statement]) throws {
        func define(_ name: String, _ stmt: Statement, line: Int) throws {
            if m.definitions[name] != nil {
                guard m.isMain else { throw PyShaderError("`\(name)` is already defined at module level", line: line) }
                return   // ShaderProgram reports it
            }
            m.definitions[name] = stmt
        }
        for stmt in body {
            switch stmt {
            case .functionDef(let d):
                try define(d.name, stmt, line: d.lineno)
            case .classDef(let c):
                try define(c.name, stmt, line: c.lineno)
            case .assign(let a):
                if a.targets.count == 1, case .name(let n) = a.targets[0] {
                    if n.id == "__all__" {
                        m.exports = try Self.exportList(a.value, line: a.lineno)
                    } else {
                        try define(n.id, stmt, line: a.lineno)
                    }
                } else if !m.isMain {
                    throw PyShaderError("module-level assignment must be `NAME = <constant expression>`", line: a.lineno)
                }
            case .annAssign(let a):
                if case .name(let n) = a.target, a.value != nil {
                    try define(n.id, stmt, line: a.lineno)
                } else if !m.isMain {
                    throw PyShaderError("module-level assignment must be `NAME: type = <constant expression>`", line: a.lineno)
                }
            case .importStmt, .importFrom, .pass, .blank:
                break
            case .expr(let e):
                if case .constant = e.value { break }
                if !m.isMain { throw PyShaderError("module-level expressions are not allowed", line: e.lineno) }
            default:
                if !m.isMain {
                    throw PyShaderError("a PyShader module may only define functions, classes and constants, and import", line: stmt.lineno)
                }
            }
        }
        for stmt in body {
            switch stmt {
            case .importStmt(let imp):
                for alias in imp.names where !ShaderProgram.isShaderModule(alias.name) {
                    try load(alias.name, line: imp.lineno, from: m)
                    if let asName = alias.asName {
                        try bind(asName, .module(alias.name), in: m, line: imp.lineno)
                    } else {
                        let top = String(alias.name.split(separator: ".")[0])
                        try bind(top, .module(top), in: m, line: imp.lineno)
                    }
                }
            case .importFrom(let imp):
                if imp.level == 0, ShaderProgram.isShaderModule(imp.module ?? "") { continue }
                let source = try absoluteModule(imp, in: m)
                try load(source, line: imp.lineno, from: m)
                for alias in imp.names {
                    if alias.name == "*" {
                        m.stars.append((source, imp.lineno))
                    } else {
                        try bind(alias.asName ?? alias.name, .member(module: source, name: alias.name, line: imp.lineno), in: m, line: imp.lineno)
                    }
                }
            default:
                break
            }
        }
    }

    private func bind(_ name: String, _ binding: ImportBinding, in m: LoadedModule, line: Int) throws {
        if m.definitions[name] != nil {
            throw PyShaderError("`\(name)` is both imported and defined at module level", line: line)
        }
        if let existing = m.bindings[name] {
            switch (existing, binding) {
            case (.module(let a), .module(let b)) where a == b: return
            case (.member(let a, let x, _), .member(let b, let y, _)) where a == b && x == y: return
            default: throw PyShaderError("`\(name)` is imported twice, as different things", line: line)
            }
        }
        m.bindings[name] = binding
    }

    /// `from .x import y` / `from .. import y` inside a package, made absolute.
    private func absoluteModule(_ imp: ImportFrom, in m: LoadedModule) throws -> String {
        guard imp.level > 0 else { return imp.module ?? "" }
        guard !m.isMain else {
            throw PyShaderError("relative import in the shader itself: it is not part of a package", line: imp.lineno)
        }
        var package = m.name.split(separator: ".").map(String.init)
        if !m.isPackage { package.removeLast() }
        guard imp.level - 1 < package.count else {
            throw PyShaderError("relative import goes above the top-level package", line: imp.lineno)
        }
        package.removeLast(imp.level - 1)
        if let module = imp.module { package.append(module) }
        return package.joined(separator: ".")
    }

    /// `__all__ = ["a", "b"]` (a list or tuple of strings).
    private static func exportList(_ value: Expression, line: Int) throws -> [String] {
        let elements: [Expression]
        switch value {
        case .list(let l): elements = l.elts
        case .tuple(let t): elements = t.elts
        default: throw PyShaderError("`__all__` must be a list of names", line: line)
        }
        return try elements.map {
            guard case .constant(let c) = $0, case .string(let s) = c.value else {
                throw PyShaderError("`__all__` must be a list of names", line: line)
            }
            return s
        }
    }

    /// Resolves every `from x import y` up front, so a name that does not
    /// exist is an error even when nothing uses it, as in Python.
    private func validateImports(_ m: LoadedModule) throws {
        for (_, binding) in m.bindings.sorted(by: { $0.key < $1.key }) {
            if case .member(let source, let name, let line) = binding {
                _ = try resolveMember(loaded[source]!, name, line: line, in: m)
            }
        }
    }

    // MARK: - Resolution

    /// What `name` means at the top level of `m`; nil when `m` does not bind
    /// it (a builtin, an input, or simply undefined).
    func resolve(_ name: String, in m: LoadedModule, line: Int) throws -> Binding? {
        if m.definitions[name] != nil { return .symbol(m, name) }
        let key = m.name + "|" + name
        guard !resolving.contains(key) else {
            throw PyShaderError("`\(name)` is imported in a circle", line: line)
        }
        resolving.insert(key)
        defer { resolving.remove(key) }

        if let binding = m.bindings[name] {
            switch binding {
            case .module(let d):
                return .module(loaded[d]!)
            case .member(let source, let member, let importLine):
                return try PyShaderError.attributing(to: m.file) {
                    try resolveMember(loaded[source]!, member, line: importLine, in: m)
                }
            }
        }
        var found: (binding: Binding, from: String)?
        for star in m.stars {
            guard let b = try exported(name, from: loaded[star.module]!, line: star.line) else { continue }
            if let previous = found, !Self.same(previous.binding, b) {
                throw PyShaderError("`\(name)` comes from both `\(previous.from)` and `\(star.module)` (`import *`); import it by name", line: line)
            }
            found = (b, star.module)
        }
        return found?.binding
    }

    /// `name` as `from s import *` sees it: public names, or `__all__`.
    private func exported(_ name: String, from s: LoadedModule, line: Int) throws -> Binding? {
        if let exports = s.exports {
            guard exports.contains(name) else { return nil }
        } else if name.hasPrefix("_") {
            return nil
        }
        return try PyShaderError.attributing(to: s.file) { try resolve(name, in: s, line: line) }
    }

    /// `name` read from module `d` (`from d import name`, `d.name`): what `d`
    /// binds it to, or its submodule of that name.
    func resolveMember(_ d: LoadedModule, _ name: String, line: Int, in importer: LoadedModule) throws -> Binding {
        if let b = try resolve(name, in: d, line: line) { return b }
        if d.isPackage, let sub = try loadIfPresent(d.name + "." + name, line: line, from: importer) {
            return .module(sub)
        }
        throw PyShaderError("module `\(d.name)` has no `\(name)`", line: line)
    }

    private static func same(_ a: Binding, _ b: Binding) -> Bool {
        switch (a, b) {
        case (.symbol(let m, let x), .symbol(let n, let y)): return m === n && x == y
        case (.module(let m), .module(let n)): return m === n
        default: return false
        }
    }

    // MARK: - Inclusion

    /// The name a definition goes by in the shader: as it is for the shader's
    /// own, `module.name` for another module's — which is pulled in, after
    /// everything it uses, the first time it is asked for.
    func include(_ m: LoadedModule, _ name: String) throws -> String {
        if m.isMain { return name }
        let qualified = m.name + "." + name
        if included.contains(qualified) { return qualified }
        included.insert(qualified)
        origins[qualified] = m.file
        let stmt = m.definitions[name]!
        let rewritten = try PyShaderError.attributing(to: m.file) {
            try ModuleRewriter(linker: self, module: m).topLevel(stmt, renamedTo: qualified)
        }
        output.append(rewritten)
        return qualified
    }
}
