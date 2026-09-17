//
//  SpirvModuleReader.swift
//  SpirvCore
//
//  Splits a SPIR-V word stream into its header and instructions; the inverse
//  of `SpirvInstruction.words`. Opcodes outside `SpirvOp` are kept as raw
//  numbers so a reader can skip or report them.
//

import Foundation

public struct SpirvReadError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct SpirvModuleReader: Sendable {
    public struct Instruction: Sendable {
        public let opcode: UInt16
        public let operands: [UInt32]
        /// The word index of the instruction in the module, for error messages.
        public let offset: Int

        public var op: SpirvOp? { SpirvOp(rawValue: opcode) }

        /// The literal string starting at operand `index`.
        public func string(at index: Int) -> (string: String, wordCount: Int) {
            SpirvInstruction.decode(string: operands, from: index)
        }
    }

    public static let magic: UInt32 = 0x0723_0203

    public let version: UInt32
    public let generator: UInt32
    public let bound: UInt32
    public let schema: UInt32
    public let instructions: [Instruction]
    /// The module as read, magic first.
    public let words: [UInt32]

    public init(words: [UInt32]) throws {
        guard words.count >= 5 else { throw SpirvReadError("module is shorter than the SPIR-V header") }
        guard words[0] == Self.magic else {
            throw SpirvReadError("bad magic number 0x\(String(words[0], radix: 16)); not a SPIR-V module")
        }
        version = words[1]
        generator = words[2]
        bound = words[3]
        schema = words[4]
        self.words = words

        var out: [Instruction] = []
        var i = 5
        while i < words.count {
            let count = Int(words[i] >> 16)
            let opcode = UInt16(words[i] & 0xFFFF)
            guard count >= 1, i + count <= words.count else {
                throw SpirvReadError("truncated instruction at word \(i)")
            }
            out.append(.init(opcode: opcode, operands: Array(words[(i + 1)..<(i + count)]), offset: i))
            i += count
        }
        instructions = out
    }

    /// Reads a `.spv` file's bytes, either endianness.
    public init(data: Data) throws {
        guard data.count % 4 == 0 else { throw SpirvReadError("byte count \(data.count) is not a multiple of 4") }
        var words = [UInt32](repeating: 0, count: data.count / 4)
        _ = words.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        if words.first == Self.magic.byteSwapped {
            words = words.map(\.byteSwapped)
        }
        try self.init(words: words)
    }
}
