import Testing
@testable import PyShader

/// Driver hints: `@inline` / `@noinline` and `unroll()` / `dont_unroll()`.
@Suite("Hints")
struct HintTests {
    @Test("@inline and @noinline set the function control")
    func functionControl() throws {
        let words = try compileValid("""
        @inline
        def a(x: float) -> float:
            return x * 2.0

        @noinline
        def b(x: float) -> float:
            return x + 1.0

        def c(x: float) -> float:
            return x

        def main(uv: float2) -> float4:
            return float4(a(uv.x), b(uv.y), c(0.5), 1.0)
        """)
        let controls = words.instructions.filter { $0.opcode == SpirvOp.opFunction.rawValue }.map { $0.operands[2] }
        #expect(controls.contains(SpirvFunctionControl.inline.rawValue))
        #expect(controls.contains(SpirvFunctionControl.dontInline.rawValue))
        #expect(controls.filter { $0 == 0 }.count >= 2, "c and the entry wrapper carry no hint")
    }

    @Test("unroll(range(...)) and dont_unroll(range(...)) set the loop control")
    func loopControl() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            s = 0.0
            for i in unroll(range(4)):
                s += float(i)
            for j in dont_unroll(range(0, 16, 2)):
                s += float(j) * 0.1
            for k in range(3):
                s += 0.01
            return float4(s)
        """)
        let controls = words.instructions.filter { $0.opcode == SpirvOp.opLoopMerge.rawValue }.map { $0.operands[2] }
        #expect(controls == [SpirvLoopControl.unroll.rawValue, SpirvLoopControl.dontUnroll.rawValue, 0])
    }

    @Test func unknownDecorator() {
        compileError("@cache\ndef f(x: float) -> float:\n    return x\ndef main(uv: float2) -> float4:\n    return float4(f(uv.x))\n", contains: "the only decorators are `@inline` and `@noinline`", line: 2)
    }

    @Test func conflictingDecorators() {
        compileError("@inline\n@noinline\ndef f(x: float) -> float:\n    return x\ndef main(uv: float2) -> float4:\n    return float4(f(uv.x))\n", contains: "both `@inline` and `@noinline`", line: 3)
    }

    @Test func unrollNeedsRange() {
        compileError("def main(uv: float2) -> float4:\n    for i in unroll(4):\n        pass\n    return float4(1.0)\n", contains: "wrap a `range(...)`", line: 2)
    }
}
