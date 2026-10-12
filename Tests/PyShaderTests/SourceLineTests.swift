import Testing
import SpirvCore
@testable import PyShader

/// `sourceFile:` puts the Python file and lines into the module (`OpString`, `OpLine`).
@Suite("Source lines")
struct SourceLineTests {
    let source = """
    def shade(t: float) -> float3:
        c = float3(t)
        return c * 0.5

    def main(uv: float2) -> float4:
        x = uv.x
        if x > 0.5:
            x = 1.0 - x
        return float4(shade(x), 1.0)
    """

    @Test("each statement is preceded by an OpLine with its Python line")
    func lines() throws {
        let shader = try PyShader.compile(source, target: .nucleant, sourceFile: "shade.py")
        if let result = try Tools.validate(shader) { #expect(result.isEmpty, "spirv-val: \(result)") }
        let reader = try SpirvModuleReader(words: shader.spirv)
        let strings = reader.instructions.filter { $0.op == .opString }
        #expect(strings.count == 1)
        #expect(strings.first?.string(at: 1).string == "shade.py")
        let file = strings[0].operands[0]
        let source = reader.instructions.first { $0.op == .opSource }
        #expect(source?.operands.count == 3 && source?.operands[2] == file, "OpSource names the file")
        let lines = reader.instructions.filter { $0.op == .opLine }.map { Int($0.operands[1]) }
        #expect(lines == [2, 3, 6, 7, 8, 9])
        #expect(reader.instructions.filter { $0.op == .opLine }.allSatisfy { $0.operands[0] == file })
    }

    @Test("without a file name the module has no line information")
    func noLines() throws {
        let words = try compileValid(source)
        #expect(!words.has(.opString) && !words.has(.opLine))
    }

    @Test("lines survive every target")
    func targets() throws {
        let compute = try PyShader.compile(source, target: .computeImage(.nucleantUI(samplesContent: false)), sourceFile: "shade.py")
        if let result = try Tools.validate(compute) { #expect(result.isEmpty, "spirv-val: \(result)") }
        #expect(SpirvWords(words: compute.spirv).count(.opLine) == 6)
    }
}
