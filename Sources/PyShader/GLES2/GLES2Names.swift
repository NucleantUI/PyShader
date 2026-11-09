//
//  GLES2Names.swift
//  PyShader
//
//  The words GLSL ES 1.00 keeps for itself. A Python name that is one of
//  them (`input`, `sample`, `length`, `half`) is renamed in the generated
//  source, so the shader compiles whatever its variables are called.
//

enum GLES2Names {
    /// Keywords and reserved words of GLSL ES 1.00, and the desktop GLSL
    /// keywords a desktop driver would also refuse.
    static let reserved: Swift.Set<String> = [
        // GLSL ES 1.00 keywords
        "attribute", "const", "uniform", "varying", "break", "continue", "do", "for", "while",
        "if", "else", "in", "out", "inout", "float", "int", "void", "bool", "true", "false",
        "lowp", "mediump", "highp", "precision", "invariant", "discard", "return",
        "mat2", "mat3", "mat4", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4",
        "bvec2", "bvec3", "bvec4", "sampler2D", "samplerCube", "struct",
        // GLSL ES 1.00 reserved for future use
        "asm", "class", "union", "enum", "typedef", "template", "this", "packed", "goto",
        "switch", "default", "inline", "noinline", "volatile", "public", "static", "extern",
        "external", "interface", "flat", "long", "short", "double", "half", "fixed",
        "unsigned", "superp", "input", "output", "hvec2", "hvec3", "hvec4", "dvec2", "dvec3",
        "dvec4", "fvec2", "fvec3", "fvec4", "sampler1D", "sampler3D", "sampler1DShadow",
        "sampler2DShadow", "sampler2DRect", "sampler3DRect", "sampler2DRectShadow",
        "sizeof", "cast", "namespace", "using",
        // later desktop GLSL keywords
        "centroid", "uint", "uvec2", "uvec3", "uvec4", "case", "sample", "layout", "smooth",
        "noperspective", "patch", "subroutine", "common", "partition", "active", "filter",
        "resource", "coherent", "restrict", "readonly", "writeonly", "buffer", "shared",
        "precise", "dmat2", "dmat3", "dmat4", "main",
    ]

    /// GLSL ES 1.00's built-in functions. A variable with one of these names
    /// would hide the function for the rest of its scope.
    static let builtinFunctions: Swift.Set<String> = [
        "radians", "degrees", "sin", "cos", "tan", "asin", "acos", "atan", "pow", "exp", "log",
        "exp2", "log2", "sqrt", "inversesqrt", "abs", "sign", "floor", "ceil", "fract", "mod",
        "min", "max", "clamp", "mix", "step", "smoothstep", "length", "distance", "dot", "cross",
        "normalize", "faceforward", "reflect", "refract", "matrixCompMult", "lessThan",
        "lessThanEqual", "greaterThan", "greaterThanEqual", "equal", "notEqual", "any", "all",
        "not", "texture2D", "texture2DProj", "texture2DLod", "texture2DProjLod", "textureCube",
        "textureCubeLod", "dFdx", "dFdy", "fwidth", "texture",
    ]

    /// `name` as GLSL may spell it: unchanged, or with a `py_` prefix when it
    /// is reserved, a built-in, starts with `gl_` or holds `__` (all of which
    /// GLSL keeps for itself).
    static func usable(_ name: String) -> Bool {
        !reserved.contains(name) && !builtinFunctions.contains(name) && !name.hasPrefix("gl_") && !name.contains("__")
    }

    static func prefixed(_ name: String) -> String {
        var body = name
        while body.contains("__") { body = body.replacingOccurrences(of: "__", with: "_u") }
        if body.hasPrefix("_") { body = "u" + body }
        return "py_" + body
    }
}
