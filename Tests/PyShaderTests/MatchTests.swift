import Testing
@testable import PyShader

/// `match` on an int or uint lowers to `OpSwitch`.
@Suite("match")
struct MatchTests {
    /// The case literals of every `OpSwitch` (the words after the selector and default, labels dropped).
    private func switchLiterals(_ words: SpirvWords) -> [[UInt32]] {
        words.instructions.filter { $0.opcode == SpirvOp.opSwitch.rawValue }.map { i in
            stride(from: 2, to: i.operands.count, by: 2).map { i.operands[$0] }
        }
    }

    @Test("literals, alternatives, negatives and a default; every case returning needs no return after")
    func basic() throws {
        let words = try compileValid("""
        def shade(k: int) -> float3:
            match k:
                case 0:
                    return float3(1.0, 0.0, 0.0)
                case 1 | 2:
                    return float3(0.0, 1.0, 0.0)
                case -3:
                    return float3(0.0, 0.0, 1.0)
                case _:
                    return float3(0.5)

        def main(uv: float2) -> float4:
            return float4(shade(int(uv.x * 4.0)), 1.0)
        """)
        #expect(words.count(.opSwitch) == 1)
        #expect(switchLiterals(words) == [[0, 1, 2, UInt32(bitPattern: -3)]])
        #expect(words.has(.opUnreachable), "the merge after a match whose cases all return is dead")
    }

    @Test("without `case _` the default is the merge; uint and short subjects")
    func subjects() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            c = float3(1.0)
            match uint(uv.y * 3.0):
                case 0:
                    c.r *= 0.5
                case 4294967295:
                    c.g = 0.0
            match short(uv.x * 3.0):
                case 2:
                    c.b = 0.0
            return float4(c, 1.0)
        """)
        #expect(words.count(.opSwitch) == 2)
        #expect(switchLiterals(words) == [[0, 4_294_967_295], [2]])
        #expect(words.has(.opSConvert), "a short subject widens to 32 bits")
    }

    @Test("a value repeated in a later case belongs to the first, as in Python")
    func duplicates() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            x = 0.0
            match int(uv.x * 4.0):
                case 1:
                    x = 1.0
                case 1 | 2:
                    x = 2.0
                case 2:
                    x = 3.0
            return float4(x)
        """)
        #expect(switchLiterals(words) == [[1, 2]])
    }

    @Test("break and continue in a case act on the loop; break goes through a flag")
    func loopControl() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            total = 0.0
            for i in range(6):
                match i:
                    case 1:
                        continue
                    case 4:
                        break
                    case 2 | 3:
                        match int(uv.x * 2.0):
                            case 0:
                                if uv.y > 0.5:
                                    break
                                total += 1.0
                            case _:
                                total += 0.25
                total += 0.01
            return float4(total)
        """)
        #expect(words.count(.opSwitch) == 2)
        // The loop is left after each switch, by `if flag: break`, never from a case:
        // naga turns a branch from a case to the loop's merge into a WGSL `break`, which
        // only leaves the switch.
        let loopMerges = Set(words.instructions.filter { $0.opcode == SpirvOp.opLoopMerge.rawValue }.map { $0.operands[0] })
        let instructions = words.instructions
        let firstSwitch = instructions.firstIndex { $0.opcode == SpirvOp.opSwitch.rawValue }!
        for (k, inst) in instructions.enumerated() where k > firstSwitch {
            if inst.opcode == SpirvOp.opBranch.rawValue, loopMerges.contains(inst.operands[0]) {
                // Only the then-block of an `if flag:` branches there: a label, then the branch.
                #expect(instructions[k - 1].opcode == SpirvOp.opLabel.rawValue, "a direct branch to the loop merge from inside a case")
            }
        }
        #expect(words.count(.opStore) >= 4, "each flag is cleared before its switch and set by a break")
    }

    @Test("a match with no loop around it needs no flag")
    func noLoopNoFlag() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            x = 0.0
            match int(uv.x * 4.0):
                case 1:
                    x = 1.0
            return float4(x)
        """)
        #expect(words.count(.opSelectionMerge) == 1)
    }

    @Test func floatSubject() {
        compileError("def main(uv: float2) -> float4:\n    match uv.x:\n        case 1:\n            pass\n    return float4(1.0)\n", contains: "int or uint subject", line: 2)
    }

    @Test func captureRefused() {
        compileError("def main(uv: float2) -> float4:\n    match int(uv.x):\n        case n:\n            pass\n    return float4(1.0)\n", contains: "would bind a new name", line: 3)
    }

    @Test func wildcardNotLast() {
        compileError("def main(uv: float2) -> float4:\n    match int(uv.x):\n        case _:\n            pass\n        case 1:\n            pass\n    return float4(1.0)\n", contains: "must be the last case", line: 5)
    }

    @Test func wildcardAlternative() {
        compileError("def main(uv: float2) -> float4:\n    match int(uv.x):\n        case 1 | _:\n            pass\n    return float4(1.0)\n", contains: "`_` cannot be one of the alternatives", line: 3)
    }

    @Test func negativeForUint() {
        compileError("def main(uv: float2) -> float4:\n    match uint(uv.x):\n        case -1:\n            pass\n    return float4(1.0)\n", contains: "out of range for a `uint`", line: 3)
    }

    @Test func nonLiteralPattern() {
        compileError("def main(uv: float2) -> float4:\n    match int(uv.x):\n        case 1.5:\n            pass\n    return float4(1.0)\n", contains: "int literals joined by `|`", line: 3)
    }
}
