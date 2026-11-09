//
//  TextureInference.swift
//  PyShader
//
//  The named textures a module samples, read off its entry points: every
//  parameter annotated `Texture` is one, so the host never has to list them.
//

import PySwiftAST

extension ShaderTarget {
    /// Where the first inferred texture is bound: NucleantUI's layout has the
    /// output at 0, the uniforms at 1, the content at 2 and the input or
    /// arguments at 3, and binds the textures from 4 in order.
    static let firstTextureBinding = 4

    /// The target with its `textures` taken from the module's entry points,
    /// when the interface lists none: each parameter annotated `Texture`, in
    /// the order the entry points declare them, gets the next binding from
    /// `firstTextureBinding`. For a vertex + fragment pair it is one set for
    /// both stages, in the order the names first appear, the vertex stage
    /// first. An interface that lists its own textures, for a host with
    /// another layout, is kept as it is, and so is a fragment target, which
    /// has no textures. They are read top-down when the interface's
    /// `texturesAreTopDown` says so, y-up otherwise.
    func inferringTextures(from module: Module) -> ShaderTarget {
        switch self {
        case .fragment:
            return self
        case .computeImage(var i):
            guard i.textures.isEmpty else { return self }
            i.textures = Self.textures(of: [i.entryPoint], in: module, isTopDown: i.texturesAreTopDown)
            return .computeImage(i)
        case .graphics(var i):
            guard i.textures.isEmpty else { return self }
            i.textures = Self.textures(of: [i.vertexEntryPoint, i.fragmentEntryPoint], in: module, isTopDown: i.texturesAreTopDown)
            return .graphics(i)
        }
    }

    private static func textures(of entryPoints: [String], in module: Module, isTopDown: Bool) -> [ShaderTexture] {
        var defs: [String: FunctionDef] = [:]
        var classes: Swift.Set<String> = []
        for stmt in module.body {
            switch stmt {
            case .functionDef(let def): defs[def.name] = defs[def.name] ?? def
            case .classDef(let c): classes.insert(c.name)
            default: break
            }
        }
        var names: [String] = []
        for entryPoint in entryPoints {
            guard let def = defs[entryPoint] else { continue }
            for arg in def.args.posonlyArgs + def.args.args
            where isTexture(arg.annotation, classes: classes) && !names.contains(arg.arg) {
                names.append(arg.arg)
            }
        }
        return names.enumerated().map { ShaderTexture(name: $1, binding: firstTextureBinding + $0, isTopDown: isTopDown) }
    }

    /// `Texture` or `pyshader.Texture`, as `ShaderProgram.resolveType` reads
    /// it; a class of the module's own called `Texture` is that class.
    private static func isTexture(_ annotation: Expression?, classes: Swift.Set<String>) -> Bool {
        switch annotation {
        case .name(let n): return !classes.contains(n.id) && ShaderType.texture(named: n.id) != nil
        case .attribute(let a): return ShaderType.texture(named: a.attr) != nil
        default: return false
        }
    }
}
