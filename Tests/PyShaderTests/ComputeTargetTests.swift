import Foundation
import Testing
@testable import PyShader

@Suite("Compute target (NucleantSwiftUI)")
struct ComputeTargetTests {
    static let plasma = """
    def main(uv: float2, time: float, resolution: float2, mouse: float2, frame: int, pixel: int2) -> float4:
        v = sin(uv.x * 10.0 + time) + float(frame % 2) + float(pixel.x)
        return float4(float3(0.5 + 0.5 * v), 1.0)
    """

    @Test("GLCompute entry point with the OGLShaderNode layout")
    func layout() throws {
        let words = try compileValid(Self.plasma, target: .nucleantSwiftUI)
        let entry = words.instructions.first { $0.opcode == SpirvOp.opEntryPoint.rawValue }!
        #expect(entry.operands[0] == SpirvExecutionModel.glCompute.rawValue)
        let mode = words.instructions.first { $0.opcode == SpirvOp.opExecutionMode.rawValue }!
        #expect(Array(mode.operands[1...]) == [SpirvExecutionMode.localSize.rawValue, 8, 8, 1])
        #expect(words.has(.opImageWrite))
        #expect(words.has(.opImageQuerySize))
        #expect(!words.has(.opImageSampleExplicitLod), "no content image unless requested")

        let bindings = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.binding.rawValue }
            .map { $0.operands[2] }
        #expect(bindings.sorted() == [0, 1])
        let offsets = words.instructions
            .filter { $0.opcode == SpirvOp.opMemberDecorate.rawValue && $0.operands[2] == SpirvDecoration.offset.rawValue }
            .map { $0.operands[3] }
        #expect(offsets == [0, 16, 32], "std140 Uniforms {vec4 timeInfo; vec4 res; vec4 mouseInfo}")
    }

    @Test("layer() samples the content image at binding 2 with explicit LOD")
    func content() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            c = layer(uv)
            return float4(c.rgb * 0.5, c.a)
        """, target: .computeImage(.nucleantSwiftUI(samplesContent: true)))
        #expect(words.count(.opImageSampleExplicitLod) == 1)
        #expect(words.has(.opTypeSampledImage))
        let bindings = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.binding.rawValue }
            .map { $0.operands[2] }
        #expect(bindings.sorted() == [0, 1, 2])
    }

    @Test("layer() without a content image is an error")
    func noContent() {
        do {
            _ = try PyShader.compile("def main(uv: float2) -> float4:\n    return layer(uv)\n", target: .nucleantSwiftUI)
            Issue.record("expected an error")
        } catch let error as PyShaderError {
            #expect(error.message.contains("content image"))
            #expect(error.line == 2)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("shader arguments: scalars, vectors and float arrays")
    func arguments() throws {
        let interface = ComputeImageInterface.nucleantSwiftUI(samplesContent: false, arguments: [
            ("gain", .float), ("tint", .float4), ("mins", .floatArray), ("size", .float2),
        ])
        let words = try compileValid("""
        def main(uv: float2, mins: FloatArray, gain: float, tint: float4, size: float2) -> float4:
            i = int(uv.x * float(len(mins)))
            return float4(tint.rgb * mins[i] * gain, size.x)
        """, target: .computeImage(interface))
        #expect(words.has(.opTypeRuntimeArray))
        let bindings = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.binding.rawValue }
            .map { $0.operands[2] }
        #expect(bindings.sorted() == [0, 1, 3])
        // The array element read clamps (SClamp) and guards the empty case (OpSelect).
        #expect(words.extInstCount(.sClamp) == 1)
        #expect(words.has(.opSelect))
    }

    @Test("FloatArray cannot be stored or passed on")
    func floatArrayMisuse() {
        let interface = ComputeImageInterface.nucleantSwiftUI(samplesContent: false, arguments: [("a", .floatArray)])
        do {
            _ = try PyShader.compile("def main(a: FloatArray) -> float4:\n    b = a\n    return float4(b[0])\n", target: .computeImage(interface))
            Issue.record("expected an error")
        } catch let error as PyShaderError {
            #expect(error.line == 2)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("every compute example compiles and validates", arguments: try computeExampleSources())
    func example(_ example: (name: String, source: String)) throws {
        let interface = ComputeImageInterface.nucleantSwiftUI(samplesContent: true, arguments: [
            ("gain", .float), ("tint", .float4), ("mins", .floatArray),
        ])
        try compileValid(example.source, target: .computeImage(interface))
    }
}

func computeExampleSources() throws -> [(name: String, source: String)] {
    let dir = examplesDirectory.appendingPathComponent("compute")
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".py") }.sorted()
    return try files.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
}
