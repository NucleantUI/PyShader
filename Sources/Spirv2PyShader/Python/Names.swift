//
//  Names.swift
//  Spirv2PyShader
//
//  Turns SPIR-V debug names into Python identifiers that do not shadow a
//  keyword, a PyShader builtin or another name in the same scope.
//

import PyShader

enum PyNames {
    static let keywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue",
        "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
        "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
        "match", "case",
    ]

    /// Every function name PyShader resolves before user functions.
    static let builtins: Set<String> = [
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
        "radians", "degrees", "pow", "exp", "exp2", "log", "log2", "sqrt", "inversesqrt", "rsqrt",
        "abs", "sign", "floor", "ceil", "round", "trunc", "fract", "mod", "min", "max", "clamp", "saturate",
        "mix", "lerp", "step", "smoothstep", "fma", "isnan", "isinf",
        "length", "distance", "dot", "cross", "normalize", "reflect", "refract", "faceforward",
        "transpose", "determinant", "inverse", "any", "all",
        "dfdx", "dFdx", "dfdy", "dFdy", "fwidth", "discard", "layer", "len", "range", "pyshader",
    ]

    static func isReserved(_ name: String) -> Bool {
        keywords.contains(name) || builtins.contains(name) || ShaderType.named(name) != nil
    }

    /// A valid identifier from a debug name: glslang's `f(vf3;f1;` mangling is
    /// cut at the `(`, other characters become `_`.
    static func sanitize(_ raw: String, fallback: String) -> String {
        var s = raw
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        var out = ""
        for c in s {
            out.append(c.isLetter || c.isNumber || c == "_" ? c : "_")
        }
        if out.isEmpty { out = fallback }
        if let first = out.first, first.isNumber { out = "_" + out }
        return out
    }
}

/// Hands out unique identifiers in one scope.
struct NameAllocator {
    private(set) var used: Set<String>

    init(reserved: Set<String> = []) {
        used = reserved
    }

    func isTaken(_ name: String) -> Bool {
        used.contains(name) || PyNames.isReserved(name)
    }

    mutating func reserve(_ name: String) {
        used.insert(name)
    }

    /// `name`, or `name_1`, `name_2`, … if it is taken.
    mutating func unique(_ raw: String, fallback: String = "v") -> String {
        let base = PyNames.sanitize(raw, fallback: fallback)
        var candidate = base
        var n = 0
        while isTaken(candidate) {
            n += 1
            candidate = "\(base)_\(n)"
        }
        used.insert(candidate)
        return candidate
    }
}
