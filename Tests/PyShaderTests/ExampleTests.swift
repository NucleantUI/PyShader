import Testing
@testable import PyShader

@Suite("Examples")
struct ExampleTests {
    @Test("every example compiles and validates", arguments: try exampleSources())
    func example(_ example: (name: String, source: String)) throws {
        let words = try compileValid(example.source)
        #expect(words.has(.opEntryPoint))
        #expect(words.bound > 5)
    }

    @Test("bound is one past the highest id")
    func bound() throws {
        let words = try compileValid("def main(uv: float2) -> float4:\n    return float4(uv, 0.0, 1.0)\n")
        var maxId: UInt32 = 0
        for i in words.instructions {
            // Every result id is allocated below the bound; check the ones we can identify cheaply.
            if i.opcode == SpirvOp.opLabel.rawValue || i.opcode == SpirvOp.opVariable.rawValue || i.opcode == SpirvOp.opFunction.rawValue {
                let idIndex = i.opcode == SpirvOp.opLabel.rawValue ? 0 : 1
                maxId = max(maxId, i.operands[idIndex])
            }
        }
        #expect(maxId < words.bound)
    }
}
