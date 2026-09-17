//
//  SpirvInstruction.swift
//  SpirvCore
//

/// One SPIR-V instruction. Encodes to `[UInt32]` as `(wordCount << 16 | opcode)` followed by operands.
public struct SpirvInstruction: Sendable {
    public var op: SpirvOp
    public var operands: [UInt32]

    public init(_ op: SpirvOp, _ operands: [UInt32] = []) {
        self.op = op
        self.operands = operands
    }

    public var words: [UInt32] {
        let count = UInt32(operands.count + 1)
        return [(count << 16) | UInt32(op.rawValue)] + operands
    }

    /// Encodes a UTF-8 string as SPIR-V literal string words (null terminated, padded to 4 bytes, little endian).
    public static func encode(string: String) -> [UInt32] {
        var bytes = Array(string.utf8)
        bytes.append(0)
        while bytes.count % 4 != 0 { bytes.append(0) }
        var out: [UInt32] = []
        out.reserveCapacity(bytes.count / 4)
        var i = 0
        while i < bytes.count {
            let w = UInt32(bytes[i])
                | (UInt32(bytes[i + 1]) << 8)
                | (UInt32(bytes[i + 2]) << 16)
                | (UInt32(bytes[i + 3]) << 24)
            out.append(w)
            i += 4
        }
        return out
    }

    /// Decodes a literal string starting at `start`; returns the string and the number of words it occupied.
    public static func decode(string words: [UInt32], from start: Int) -> (string: String, wordCount: Int) {
        var bytes: [UInt8] = []
        var i = start
        while i < words.count {
            let w = words[i]
            i += 1
            var terminated = false
            for shift in stride(from: 0, through: 24, by: 8) {
                let b = UInt8((w >> UInt32(shift)) & 0xFF)
                if b == 0 { terminated = true; break }
                bytes.append(b)
            }
            if terminated { break }
        }
        return (String(decoding: bytes, as: UTF8.self), i - start)
    }
}

/// IEEE 754 binary16 encoding of a float (round-to-nearest-even). `Float16` is unavailable on x86_64 macOS.
public func halfBits(_ f: Float) -> UInt16 {
    let bits = f.bitPattern
    let sign = UInt16((bits >> 16) & 0x8000)
    let exp = Int((bits >> 23) & 0xFF) - 127 + 15
    var mant = bits & 0x7F_FFFF
    if (bits & 0x7F80_0000) == 0x7F80_0000 {
        // inf / nan
        return sign | 0x7C00 | (mant != 0 ? 0x200 : 0)
    }
    if exp >= 0x1F { return sign | 0x7C00 }
    if exp <= 0 {
        if exp < -10 { return sign }
        mant |= 0x80_0000
        let shift = UInt32(14 - exp)
        var half = UInt16(mant >> shift)
        let rem = mant & ((1 << shift) - 1)
        let halfway: UInt32 = 1 << (shift - 1)
        if rem > halfway || (rem == halfway && (half & 1) == 1) { half += 1 }
        return sign | half
    }
    var half = UInt16(exp << 10) | UInt16(mant >> 13)
    let rem = mant & 0x1FFF
    if rem > 0x1000 || (rem == 0x1000 && (half & 1) == 1) { half += 1 }
    return sign | half
}

/// The float a binary16 bit pattern stands for; the inverse of `halfBits`.
public func floatFromHalfBits(_ h: UInt16) -> Float {
    let sign: UInt32 = UInt32(h & 0x8000) << 16
    let exp = Int((h >> 10) & 0x1F)
    let mant = UInt32(h & 0x3FF)
    if exp == 0x1F {
        return Float(bitPattern: sign | 0x7F80_0000 | (mant << 13))
    }
    if exp == 0 {
        if mant == 0 { return Float(bitPattern: sign) }
        // subnormal: value = mant * 2^-24
        return Float(sign: h & 0x8000 != 0 ? .minus : .plus, exponent: -24, significand: Float(mant))
    }
    return Float(bitPattern: sign | UInt32(exp - 15 + 127) << 23 | (mant << 13))
}
