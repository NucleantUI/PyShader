//
//  Std430.swift
//  PyShader
//
//  Where a value sits in a storage buffer: the std430 rules a host follows to
//  write the bytes a `class` input is read from.
//

extension ShaderType {

    /// Size and alignment in a std430 buffer; nil for a type a buffer cannot
    /// hold as it is — a `bool`, which has no layout, a 16- or 64-bit value,
    /// which needs a capability, a handle, or anything open-ended.
    ///
    /// 32-bit scalars are 4 and 4; a `float2` 8 and 8; a `float3` 12 and 16,
    /// so a scalar after it fills its fourth slot; a `float4` 16 and 16. An
    /// array's elements are each rounded up to their alignment (a `float3`
    /// array has a 16-byte stride); a matrix is an array of its columns; a
    /// class aligns to its widest field and is rounded up to that.
    var std430: (size: Int, alignment: Int)? {
        switch self {
        case .scalar(let kind):
            switch kind {
            case .float(bits: 32), .int(bits: 32, signed: _): return (4, 4)
            default: return nil
            }
        case .vector(let kind, let n):
            guard ShaderType.scalar(kind).std430 != nil else { return nil }
            switch n {
            case 2: return (8, 8)
            case 3: return (12, 16)
            case 4: return (16, 16)
            default: return nil
            }
        case .matrix(let kind, let columns, let rows):
            guard let column = ShaderType.vector(kind, rows).std430 else { return nil }
            return (Self.roundUp(column.size, to: column.alignment) * columns, column.alignment)
        case .array(let element, let count):
            // A list of matrices would need its matrix stride decorated on
            // the list, which has nowhere to carry it; a class of one has.
            if case .matrix = element { return nil }
            guard count > 0, let stride = element.std430Stride, let alignment = element.std430?.alignment else { return nil }
            return (stride * count, alignment)
        case .structure(_, let members):
            guard let offsets = std430Offsets, !members.isEmpty else { return nil }
            var alignment = 1
            var end = 0
            for (offset, member) in zip(offsets, members) {
                let layout = member.1.std430!
                alignment = max(alignment, layout.alignment)
                end = offset + layout.size
            }
            return (Self.roundUp(end, to: alignment), alignment)
        default:
            return nil
        }
    }

    /// Each field's byte offset, for a class whose every field has a layout.
    var std430Offsets: [Int]? {
        guard case .structure(_, let members) = self else { return nil }
        var offsets: [Int] = []
        var end = 0
        for (_, type) in members {
            guard let layout = type.std430 else { return nil }
            let offset = Self.roundUp(end, to: layout.alignment)
            offsets.append(offset)
            end = offset + layout.size
        }
        return offsets
    }

    /// The distance between consecutive elements of an array of this type.
    var std430Stride: Int? {
        guard let layout = std430 else { return nil }
        return Self.roundUp(layout.size, to: layout.alignment)
    }

    private static func roundUp(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }
}
