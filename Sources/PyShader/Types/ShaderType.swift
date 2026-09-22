//
//  ShaderType.swift
//  PyShader
//

/// Scalar element kinds available to shader code.
import SpirvCore

public enum ScalarKind: Hashable, Sendable {
    case bool
    case float(bits: Int)
    case int(bits: Int, signed: Bool)

    public var isFloat: Bool {
        if case .float = self { return true }
        return false
    }

    public var isInt: Bool {
        if case .int = self { return true }
        return false
    }

    public var isSigned: Bool {
        if case .int(_, let signed) = self { return signed }
        return true
    }

    public var isBool: Bool { self == .bool }

    public var bits: Int {
        switch self {
        case .bool: return 1
        case .float(let bits): return bits
        case .int(let bits, _): return bits
        }
    }

    /// Python-facing spelling of the scalar.
    public var name: String {
        switch self {
        case .bool: return "bool"
        case .float(16): return "half"
        case .float: return "float"
        case .int(16, true): return "short"
        case .int(16, false): return "ushort"
        case .int(_, true): return "int"
        case .int(_, false): return "uint"
        }
    }
}

/// Opaque resource types used by the entry-point wrappers.
public enum ImageKind: Hashable, Sendable {
    /// `writeonly image2D` with an rgba8 format (a compute shader's output).
    case storage2DRgba8
    /// `sampler2D` (a texture read through a sampler).
    case sampled2D
}

/// The types PyShader can express.
public indirect enum ShaderType: Hashable, Sendable, CustomStringConvertible {
    case void
    case scalar(ScalarKind)
    case vector(ScalarKind, Int)
    /// Column-major float matrix, `columns` column vectors of `rows` components (Metal's `floatCxR`).
    case matrix(ScalarKind, columns: Int, rows: Int)
    /// Fixed-size array, as a Python list literal of one element type produces.
    case array(ShaderType, Int)
    /// Several values returned together (`-> tuple[float, float3]`); a struct in SPIR-V.
    case tuple([ShaderType])
    /// A (Block-decorated) struct, used for push-constant / uniform / storage blocks.
    case structure(name: String, members: [(String, ShaderType)])
    case pointer(SpirvStorageClass, ShaderType)
    case function(returns: ShaderType, params: [ShaderType])
    case image(ImageKind)
    case sampledImage(ImageKind)
    /// An unsized array, the last member of a storage block.
    case runtimeArray(ShaderType)
    /// A handle to one array shader argument (compile-time index into the argument buffer),
    /// of `float` or `float2`/`float3`/`float4` elements. Not a storable value: indexed
    /// with `a[i]`, measured with `len(a)`.
    case floatArray(argument: Int, element: ShaderType)

    public static let bool: ShaderType = .scalar(.bool)
    public static let float: ShaderType = .scalar(.float(bits: 32))
    public static let half: ShaderType = .scalar(.float(bits: 16))
    public static let int: ShaderType = .scalar(.int(bits: 32, signed: true))
    public static let uint: ShaderType = .scalar(.int(bits: 32, signed: false))
    public static let short: ShaderType = .scalar(.int(bits: 16, signed: true))
    public static let ushort: ShaderType = .scalar(.int(bits: 16, signed: false))

    public static func float(_ n: Int) -> ShaderType { n == 1 ? .float : .vector(.float(bits: 32), n) }
    public static func half(_ n: Int) -> ShaderType { n == 1 ? .half : .vector(.float(bits: 16), n) }
    public static func int(_ n: Int) -> ShaderType { n == 1 ? .int : .vector(.int(bits: 32, signed: true), n) }
    public static func uint(_ n: Int) -> ShaderType { n == 1 ? .uint : .vector(.int(bits: 32, signed: false), n) }
    public static func short(_ n: Int) -> ShaderType { n == 1 ? .short : .vector(.int(bits: 16, signed: true), n) }
    public static func ushort(_ n: Int) -> ShaderType { n == 1 ? .ushort : .vector(.int(bits: 16, signed: false), n) }
    public static func bool(_ n: Int) -> ShaderType { n == 1 ? .bool : .vector(.bool, n) }

    /// Scalar element kind for scalars and vectors; nil otherwise.
    public var scalarKind: ScalarKind? {
        switch self {
        case .scalar(let k): return k
        case .vector(let k, _): return k
        default: return nil
        }
    }

    /// 1 for scalars, N for vectors, 0 otherwise.
    public var componentCount: Int {
        switch self {
        case .scalar: return 1
        case .vector(_, let n): return n
        default: return 0
        }
    }

    public var isScalar: Bool {
        if case .scalar = self { return true }
        return false
    }

    public var isVector: Bool {
        if case .vector = self { return true }
        return false
    }

    public var isNumeric: Bool {
        guard let k = scalarKind else { return false }
        return !k.isBool
    }

    /// Can live in a variable, be passed and returned.
    public var isStorable: Bool {
        switch self {
        case .scalar, .vector, .matrix, .tuple: return true
        case .structure(_, let members): return members.allSatisfy { $0.1.isStorable }
        case .array(let t, let n): return n >= 0 && t.isStorable
        default: return false
        }
    }

    public var isMatrix: Bool {
        if case .matrix = self { return true }
        return false
    }

    /// Column count of a matrix, element count of an array, member count of a tuple.
    public var count: Int {
        switch self {
        case .matrix(_, let c, _): return c
        case .array(_, let n): return n
        case .tuple(let ts): return ts.count
        default: return componentCount
        }
    }

    /// The type `self[i]` yields: vector -> scalar, matrix -> column, array -> element.
    public func elementType(at index: Int? = nil) -> ShaderType? {
        switch self {
        case .scalar, .vector: return elementType
        case .matrix(let k, _, let rows): return .vector(k, rows)
        case .array(let t, _): return t
        case .tuple(let ts):
            guard let index, ts.indices.contains(index) else { return nil }
            return ts[index]
        default: return nil
        }
    }

    public var isFloatArray: Bool {
        if case .floatArray = self { return true }
        return false
    }

    /// The Python-facing names of the argument array types, `FloatArray` and
    /// `Float2Array`…`Float4Array`, by element type.
    static let argumentArrayNames: [(name: String, element: ShaderType)] = [
        ("FloatArray", .float), ("Float2Array", .float(2)), ("Float3Array", .float(3)), ("Float4Array", .float(4)),
    ]

    /// The argument array type called `name`, as an annotation resolves it
    /// (bound to no argument yet), or nil for any other name.
    public static func argumentArray(named name: String) -> ShaderType? {
        argumentArrayNames.first { $0.name == name }.map { .floatArray(argument: -1, element: $0.element) }
    }

    public var isFloat: Bool { scalarKind?.isFloat ?? false }
    public var isInt: Bool { scalarKind?.isInt ?? false }
    public var isBool: Bool { scalarKind?.isBool ?? false }

    /// The scalar type of a scalar or vector.
    public var elementType: ShaderType? {
        scalarKind.map { .scalar($0) }
    }

    /// Same scalar kind, different arity.
    public func with(components n: Int) -> ShaderType? {
        guard let k = scalarKind else { return nil }
        return n == 1 ? .scalar(k) : .vector(k, n)
    }

    public var description: String {
        switch self {
        case .void: return "None"
        case .scalar(let k): return k.name
        case .vector(let k, let n): return "\(k.name)\(n)"
        case .matrix(let k, let c, let r): return "\(k.name)\(c)x\(r)"
        case .array(let t, let n): return "list[\(t)] (\(n))"
        case .tuple(let ts): return "tuple[\(ts.map(\.description).joined(separator: ", "))]"
        case .structure(let name, _): return name
        case .pointer(_, let t): return "ptr<\(t)>"
        case .function(let r, let p): return "(\(p.map(\.description).joined(separator: ", "))) -> \(r)"
        case .image(.storage2DRgba8): return "image2D"
        case .image(.sampled2D): return "texture2D"
        case .sampledImage: return "sampler2D"
        case .runtimeArray(let t): return "\(t)[]"
        case .floatArray(_, let element): return Self.argumentArrayNames.first { $0.element == element }?.name ?? "\(element)Array"
        }
    }

    /// Looks up a Python-facing type name such as `float3` or `int`.
    public static func named(_ name: String) -> ShaderType? {
        if let t = scalarNames[name] { return t }
        // float3x3 / half2x4: columns x rows
        let parts = name.split(separator: "x")
        if parts.count == 2, let rows = Int(parts[1]), (2...4).contains(rows),
           let last = parts[0].last, let cols = Int(String(last)), (2...4).contains(cols),
           let base = scalarNames[String(parts[0].dropLast())], let k = base.scalarKind, k.isFloat {
            return .matrix(k, columns: cols, rows: rows)
        }
        guard let last = name.last, let n = Int(String(last)), (2...4).contains(n) else { return nil }
        let base = String(name.dropLast())
        guard let s = scalarNames[base], let k = s.scalarKind else { return nil }
        return .vector(k, n)
    }

    private static let scalarNames: [String: ShaderType] = [
        "bool": .bool,
        "float": .float,
        "half": .half,
        "int": .int,
        "uint": .uint,
        "short": .short,
        "ushort": .ushort,
    ]

    // MARK: Hashable for the struct case (members contain tuples)

    public static func == (lhs: ShaderType, rhs: ShaderType) -> Bool {
        switch (lhs, rhs) {
        case (.void, .void): return true
        case (.scalar(let a), .scalar(let b)): return a == b
        case (.vector(let a, let n), .vector(let b, let m)): return a == b && n == m
        case (.matrix(let a, let ac, let ar), .matrix(let b, let bc, let br)): return a == b && ac == bc && ar == br
        case (.array(let a, let n), .array(let b, let m)): return a == b && n == m
        case (.tuple(let a), .tuple(let b)): return a == b
        case (.structure(let an, let am), .structure(let bn, let bm)):
            return an == bn && am.count == bm.count && zip(am, bm).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.pointer(let a, let at), .pointer(let b, let bt)): return a == b && at == bt
        case (.function(let ar, let ap), .function(let br, let bp)): return ar == br && ap == bp
        case (.image(let a), .image(let b)): return a == b
        case (.sampledImage(let a), .sampledImage(let b)): return a == b
        case (.runtimeArray(let a), .runtimeArray(let b)): return a == b
        case (.floatArray(let a, let ae), .floatArray(let b, let be)): return a == b && ae == be
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .void: hasher.combine(0)
        case .scalar(let k): hasher.combine(1); hasher.combine(k)
        case .vector(let k, let n): hasher.combine(2); hasher.combine(k); hasher.combine(n)
        case .matrix(let k, let c, let r): hasher.combine(10); hasher.combine(k); hasher.combine(c); hasher.combine(r)
        case .array(let t, let n): hasher.combine(11); hasher.combine(t); hasher.combine(n)
        case .tuple(let ts): hasher.combine(12); hasher.combine(ts)
        case .structure(let name, let members):
            hasher.combine(3); hasher.combine(name)
            for (n, t) in members { hasher.combine(n); hasher.combine(t) }
        case .pointer(let sc, let t): hasher.combine(4); hasher.combine(sc.rawValue); hasher.combine(t)
        case .function(let r, let p): hasher.combine(5); hasher.combine(r); hasher.combine(p)
        case .image(let k): hasher.combine(6); hasher.combine(k)
        case .sampledImage(let k): hasher.combine(7); hasher.combine(k)
        case .runtimeArray(let t): hasher.combine(8); hasher.combine(t)
        case .floatArray(let i, let element): hasher.combine(9); hasher.combine(i); hasher.combine(element)
        }
    }
}
