import Testing
import SpirvCore

@Suite("SpirvCore")
struct SpirvCoreTests {
    @Test("strings encode and decode")
    func strings() {
        for s in ["", "a", "abc", "abcd", "GLSL.std.450", "mainImage(vf4;vf2;"] {
            let words = SpirvInstruction.encode(string: s)
            #expect(words.count == s.utf8.count / 4 + 1)
            let (back, count) = SpirvInstruction.decode(string: [7, 7] + words, from: 2)
            #expect(back == s)
            #expect(count == words.count)
        }
    }

    @Test("the reader splits a module into instructions")
    func reader() throws {
        var words: [UInt32] = [SpirvModuleReader.magic, 0x0001_0000, 0, 10, 0]
        words += SpirvInstruction(.opCapability, [SpirvCapability.shader.rawValue]).words
        words += SpirvInstruction(.opExtInstImport, [1] + SpirvInstruction.encode(string: "GLSL.std.450")).words
        words += SpirvInstruction(.opTypeVoid, [2]).words
        let reader = try SpirvModuleReader(words: words)
        #expect(reader.bound == 10)
        #expect(reader.instructions.map(\.op) == [.opCapability, .opExtInstImport, .opTypeVoid])
        #expect(reader.instructions[1].string(at: 1).string == "GLSL.std.450")
        #expect(reader.instructions[2].offset == words.count - 2)
    }

    @Test("a bad magic number is refused")
    func badMagic() {
        #expect(throws: SpirvReadError.self) { try SpirvModuleReader(words: [1, 2, 3, 4, 5]) }
    }

    @Test("half conversion round-trips")
    func half() {
        for f: Float in [0, 1, -1, 0.5, 0.1, 65504, 1e-5, -3.25] {
            let back = floatFromHalfBits(halfBits(f))
            #expect(abs(back - f) <= max(abs(f) * 0.001, 1e-7), "\(f) -> \(back)")
        }
        #expect(floatFromHalfBits(halfBits(.infinity)) == .infinity)
        #expect(floatFromHalfBits(halfBits(.nan)).isNaN)
    }
}
