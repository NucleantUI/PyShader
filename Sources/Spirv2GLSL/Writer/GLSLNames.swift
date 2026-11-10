//
//  GLSLNames.swift
//  Spirv2GLSL
//
//  Names GLSL ES 1.00 lets a shader declare. A module's names (OpName) are
//  kept when GLSL allows them and are free; otherwise they get a suffix.
//  Interface names (attributes, varyings, uniforms) are the host's and are
//  never changed: one GLSL cannot declare is an error.
//

import Foundation

/// Keywords and the words GLSL ES 1.00 reserves (its 3.7), the types, and
/// the built-in functions, which a declaration of the same name would hide.
let glslReservedNames: Set<String> = [
        // keywords
        "attribute", "const", "uniform", "varying", "break", "continue", "do", "for", "while",
        "if", "else", "in", "out", "inout", "float", "int", "void", "bool", "true", "false",
        "lowp", "mediump", "highp", "precision", "invariant", "discard", "return",
        "mat2", "mat3", "mat4", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4",
        "bvec2", "bvec3", "bvec4", "sampler2D", "samplerCube", "struct",
        // reserved for future use
        "asm", "class", "union", "enum", "typedef", "template", "this", "packed", "goto",
        "switch", "default", "inline", "noinline", "volatile", "public", "static", "extern",
        "external", "interface", "flat", "long", "short", "double", "half", "fixed",
        "unsigned", "superp", "input", "output", "hvec2", "hvec3", "hvec4", "dvec2", "dvec3",
        "dvec4", "fvec2", "fvec3", "fvec4", "sampler1D", "sampler3D", "sampler1DShadow",
        "sampler2DShadow", "sampler2DRect", "sampler3DRect", "sampler2DRectShadow",
        "sizeof", "cast", "namespace", "using",
        // later GLSL's keywords, so the source also compiles as desktop GLSL
        "case", "centroid", "layout", "patch", "sample", "subroutine", "smooth",
        "noperspective", "uint", "uvec2", "uvec3", "uvec4", "mat2x2", "mat2x3", "mat2x4",
        "mat3x2", "mat3x3", "mat3x4", "mat4x2", "mat4x3", "mat4x4", "dmat2", "dmat3", "dmat4",
        "image2D", "texture", "buffer", "shared", "coherent", "restrict", "readonly", "writeonly",
        "resource", "atomic_uint", "common", "partition", "active", "filter", "precise",
        // built-in functions
        "radians", "degrees", "sin", "cos", "tan", "asin", "acos", "atan", "pow", "exp", "log",
        "exp2", "log2", "sqrt", "inversesqrt", "abs", "sign", "floor", "ceil", "fract", "mod",
        "min", "max", "clamp", "mix", "step", "smoothstep", "length", "distance", "dot",
        "cross", "normalize", "faceforward", "reflect", "refract", "matrixCompMult",
        "lessThan", "lessThanEqual", "greaterThan", "greaterThanEqual", "equal", "notEqual",
        "any", "all", "not", "texture2D", "texture2DProj", "texture2DLod", "texture2DProjLod",
        "textureCube", "textureCubeLod", "texture2DLodEXT", "texture2DProjLodEXT",
        "textureCubeLodEXT", "texture2DGradEXT", "dFdx", "dFdy", "fwidth",
        // the entry point
        "main",
]

/// Names in use in one scope and the ones around it.
final class NameScope {
    private var used: Set<String>
    private let parent: NameScope?

    init(parent: NameScope? = nil, reserving: Set<String> = []) {
        self.parent = parent
        self.used = reserving
    }

    /// Whether GLSL lets a shader declare `name` as it is.
    func isDeclarable(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || ("a"..."z").contains(first) || ("A"..."Z").contains(first) else {
            return false
        }
        guard name.unicodeScalars.allSatisfy({ $0 == "_" || ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else {
            return false
        }
        return !name.hasPrefix("gl_") && !name.contains("__") && !glslReservedNames.contains(name)
    }

    /// `name` made into one GLSL lets a shader declare: other characters
    /// become `_`, and a reserved or built-in name gets a `_` after it.
    func sanitize(_ name: String) -> String {
        var out = String(name.unicodeScalars.map { s -> Character in
            s == "_" || ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s) ? Character(s) : "_"
        })
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        if out.isEmpty || out.first!.isNumber { out = "v" + out }
        if out.hasPrefix("gl_") { out = "g" + out }
        if glslReservedNames.contains(out) { out += "_" }
        // `_` + a trailing `_` can make `__` again: a final pass.
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        if glslReservedNames.contains(out) { out = "v_" + out }
        return out
    }

    func isFree(_ name: String) -> Bool {
        !used.contains(name) && (parent?.isFree(name) ?? true)
    }

    /// Takes `name` exactly; false when it is not free.
    @discardableResult
    func claim(_ name: String) -> Bool {
        guard isFree(name) else { return false }
        used.insert(name)
        return true
    }

    /// A free name from `base` (sanitized), suffixed `_2`, `_3`… when taken.
    func unique(_ base: String) -> String {
        let clean = sanitize(base)
        if claim(clean) { return clean }
        var k = 2
        let stem = clean.hasSuffix("_") ? String(clean.dropLast()) : clean
        while !claim("\(stem)_\(k)") { k += 1 }
        return "\(stem)_\(k)"
    }
}
