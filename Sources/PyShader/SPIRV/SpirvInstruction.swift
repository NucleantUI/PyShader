//
//  SpirvInstruction.swift
//  PyShader
//

/// One SPIR-V instruction. Encodes to `[UInt32]` as `(wordCount << 16 | opcode)` followed by operands.
struct SpirvInstruction: Sendable {
    var op: SpirvOp
    var operands: [UInt32]

    init(_ op: SpirvOp, _ operands: [UInt32] = []) {
        self.op = op
        self.operands = operands
    }

    var words: [UInt32] {
        let count = UInt32(operands.count + 1)
        return [(count << 16) | UInt32(op.rawValue)] + operands
    }

    /// Encodes a UTF-8 string as SPIR-V literal string words (null terminated, padded to 4 bytes, little endian).
    static func encode(string: String) -> [UInt32] {
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
}
