import Foundation
import Testing
@testable import PyShader

@Suite("Matrices, tuples and lists")
struct CompositeTests {
    @Test("matrix products pick the right instruction")
    func matrices() throws {
        let words = try compileValid("""
        def rot(a: float) -> float2x2:
            return float2x2(cos(a), sin(a), -sin(a), cos(a))
        def main(uv: float2, time: float) -> float4:
            m = rot(time)
            p = m * uv              # matrix * vector
            q = uv * m              # vector * matrix
            n = m * rot(0.5)        # matrix * matrix
            s = m * 2.0             # matrix * scalar
            k = (n + s - m) / 2.0
            d = p @ q               # dot
            c = transpose(k)[0] + inverse(k)[1] * determinant(k)
            e = float3x3(m)[2] + float3x3()[0] + float3x3(2.0)[1]
            return float4(c + e.xy, d, len(m))
        """)
        #expect(words.count(.opMatrixTimesVector) == 1)
        #expect(words.count(.opVectorTimesMatrix) == 1)
        #expect(words.count(.opMatrixTimesMatrix) == 1)
        #expect(words.count(.opMatrixTimesScalar) == 2, "m * 2.0 and / 2.0")
        #expect(words.count(.opDot) == 1)
        #expect(words.has(.opTranspose))
        #expect(words.extInstCount(.determinant) == 1)
        #expect(words.extInstCount(.matrixInverse) == 1)
    }

    @Test("tuple returns unpack at the call site")
    func tuples() throws {
        let words = try compileValid("""
        MISS = (False, -1.0, float3(0.0))
        def box(ro: float3, rd: float3) -> tuple[bool, float, float3]:
            if rd.z == 0.0:
                return MISS
            return True, -ro.z / rd.z, float3(0.0, 0.0, 1.0)
        def main(uv: float2) -> float4:
            hit, t, n = box(float3(uv, -1.0), float3(0.0, 0.0, 1.0))
            r = box(float3(0.0), float3(uv, 1.0))
            return float4(n * t, 1.0 if hit and r[0] else r[1])
        """)
        #expect(words.count(.opTypeStruct) == 1)
        #expect(words.count(.opFunctionCall) == 3)
    }

    @Test("lists: literal, repeat, dynamic index, swap, len")
    func lists() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            colx = [float4(0.0)] * 3
            order = [0, 1, 2]
            w: list[float] = [0.13, 0.07, 0.03]
            for i in range(3):
                colx[i] = float4(uv, w[i], float(i))
                colx[i].x += w[i]
            if colx[0].z < colx[1].z:
                colx[0], colx[1] = colx[1], colx[0]
                order[0], order[1] = order[1], order[0]
            k = int(uv.x * 3.0)
            return colx[order[k]] * float(len(w))
        """)
        #expect(words.count(.opTypeArray) == 4, "float4[1] (before the repeat), float4[3], int[3], float[3]")
        #expect(words.has(.opAccessChain))
    }

    @Test("derivatives and discard are fragment-only")
    func fragmentOnly() {
        for call in ["fwidth(uv.x)", "dfdx(uv.x)"] {
            do {
                _ = try PyShader.compile("def main(uv: float2) -> float4:\n    return float4(\(call))\n", target: .nucleantSwiftUI)
                Issue.record("expected an error for \(call)")
            } catch let error as PyShaderError {
                #expect(error.message.contains("fragment target"))
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
        #expect(throws: Never.self) {
            try PyShader.compile("def main(uv: float2) -> float4:\n    return float4(fwidth(uv.x))\n")
        }
    }

    @Test("every ShaderToy port compiles for the compute target", arguments: try shadertoyPorts())
    func shadertoy(_ port: (name: String, source: String)) throws {
        try compileValid(port.source, target: .nucleantSwiftUI)
    }
}

func shadertoyPorts() throws -> [(name: String, source: String)] {
    let dir = examplesDirectory.appendingPathComponent("shadertoy/pyshader")
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".py") }.sorted()
    return try files.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
}
