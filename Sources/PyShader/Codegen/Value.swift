//
//  Value.swift
//  PyShader
//

/// An SSA result id together with its shader type.
struct Value {
    let id: SpirvId
    let type: ShaderType
}

/// A storable location: a whole variable, one component of a vector variable, or a swizzled subset.
enum LValue {
    case variable(ptr: SpirvId, type: ShaderType)
    case component(ptr: SpirvId, index: SpirvId, vectorType: ShaderType)
    case swizzle(ptr: SpirvId, vectorType: ShaderType, indices: [Int])

    var type: ShaderType {
        switch self {
        case .variable(_, let t): return t
        case .component(_, _, let v): return v.elementType!
        case .swizzle(_, let v, let idx): return v.with(components: idx.count)!
        }
    }
}

/// A local variable inside a function.
struct LocalVariable {
    let ptr: SpirvId
    let type: ShaderType
}

/// Swizzle component letters. `.xyzw` and `.rgba` may not be mixed.
enum Swizzle {
    private static let xyzw: [Character: Int] = ["x": 0, "y": 1, "z": 2, "w": 3]
    private static let rgba: [Character: Int] = ["r": 0, "g": 1, "b": 2, "a": 3]

    /// Returns component indices for an attribute name, or nil if it is not a swizzle.
    static func indices(for attr: String) -> [Int]? {
        guard (1...4).contains(attr.count) else { return nil }
        if let idx = map(attr, Self.xyzw) { return idx }
        if let idx = map(attr, Self.rgba) { return idx }
        return nil
    }

    private static func map(_ attr: String, _ table: [Character: Int]) -> [Int]? {
        var out: [Int] = []
        for c in attr {
            guard let i = table[c] else { return nil }
            out.append(i)
        }
        return out
    }
}
