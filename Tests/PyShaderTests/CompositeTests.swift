import Foundation
import Testing
@testable import PyShader

/// The `OpName` strings of a module.
private func opNames(_ words: SpirvWords) -> [String] {
    words.instructions.filter { $0.opcode == SpirvOp.opName.rawValue }.map { instruction in
        var bytes: [UInt8] = []
        for word in instruction.operands.dropFirst() {
            for k in 0..<4 {
                let b = UInt8((word >> (8 * k)) & 0xFF)
                if b == 0 { return String(decoding: bytes, as: UTF8.self) }
                bytes.append(b)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

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

    @Test("lists nest: a list of lists indexes, assigns and counts at each level")
    func nestedLists() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            g = [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]
            i = int(uv.x * 2.0)
            g[i][1] = 7.0
            g[2] = [8.0, 9.0]
            return float4(g[i][0], g[1][i], float(len(g)), float(len(g[0])))
        """)
        #expect(words.count(.opTypeArray) == 2, "float[2] and float[2][3]")
        #expect(words.has(.opAccessChain))
    }

    @Test("a function taking list[T] is compiled once per length it is called with")
    func listParameters() throws {
        let words = try compileValid("""
        def total(xs: list[float]) -> float:
            t = 0.0
            for i in range(len(xs)):
                t += xs[i]
            return t
        def twice(xs: list[float]) -> float:
            return total(xs) * 2.0
        def main(uv: float2) -> float4:
            a = [uv.x, uv.y, 1.0]
            return float4(total(a), total([uv.x, 2.0]), twice(a), total([1, 2, 3, 4]))
        """)
        let names = opNames(words)
        // Lengths 3, 2 and 4; `twice` reuses the length-3 `total`.
        #expect(names.filter { $0.hasPrefix("total") }.sorted() == ["total", "total_2", "total_3"])
        #expect(names.filter { $0.hasPrefix("twice") } == ["twice"])
    }

    @Test("a list parameter is the function's own copy; values fold to the right results", .enabled(if: Tools.spirvOpt != nil, "spirv-opt not installed"))
    func listParameterValues() throws {
        let shader = try PyShader.compile("""
        def total(xs: list[float]) -> float:
            t = 0.0
            for i in unroll(range(len(xs))):
                t += xs[i]
            xs[0] = 100.0
            return t
        def first(xs: list[float]) -> float:
            return xs[0]
        def main(uv: float2) -> float4:
            ws = [1.5, 2.0, 3.0]
            return float4(total(ws), total([10.0, 20.0]), first(ws), total([1, 2, 3, 4]))
        """)
        guard let folded = try Tools.optimize(shader) else { return }
        let values = folded.scalarConstants.map { Float(bitPattern: $0) }
        for value: Float in [6.5, 30, 1.5, 10] {
            #expect(values.contains(value), "\(value) in \(values)")
        }
        #expect(!values.contains(101.5), "the caller's list is unchanged")
    }

    @Test("a polygon's distance, over a list of corners", .enabled(if: Tools.spirvOpt != nil, "spirv-opt not installed"))
    func polygon() throws {
        let shader = try PyShader.compile("""
        def sd_polygon(v: list[float2], p: float2) -> float:
            d = dot(p - v[0], p - v[0])
            s = 1.0
            j = len(v) - 1
            for i in unroll(range(len(v))):
                e = v[j] - v[i]
                w = p - v[i]
                b = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0)
                d = min(d, dot(b, b))
                # Scalar booleans: spirv-opt folds and / or, not any() / all().
                a = p.y >= v[i].y
                b2 = p.y < v[j].y
                k = e.x * w.y > e.y * w.x
                if (a and b2 and k) or not (a or b2 or k):
                    s = -s
                j = i
            return s * sqrt(d)
        def main(uv: float2) -> float4:
            square = [float2(0.0, 0.0), float2(1.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0)]
            triangle = [float2(0.0, 0.0), float2(4.0, 0.0), float2(0.0, 3.0)]
            return float4(sd_polygon(square, float2(0.5, 0.25)), sd_polygon(square, float2(3.0, 0.5)),
                          sd_polygon(triangle, float2(4.0, 3.0)), 1.0)
        """)
        guard let folded = try Tools.optimize(shader) else { return }
        let values = folded.scalarConstants.map { Float(bitPattern: $0) }
        // Inside the square, 0.25 from its bottom edge; 2 to the right of it;
        // 2.4 off the triangle's long edge.
        for value: Float in [-0.25, 2.0, 2.4] {
            #expect(values.contains { abs($0 - value) < 1e-4 }, "\(value) in \(values)")
        }
    }

    @Test("an array argument passes to a function taking list[T] or the array type, one instance per argument")
    func arrayArgumentParameters() throws {
        let interface = ComputeImageInterface.nucleantUI(samplesContent: false, arguments: [
            ("points", .float2Array), ("more", .float2Array), ("weights", .floatArray),
        ])
        let words = try compileValid("""
        def centroid(pts: list[float2]) -> float2:
            c = float2(0.0)
            for i in range(len(pts)):
                c += pts[i]
            return c / float(max(len(pts), 1))
        def weight(w: FloatArray, i: int) -> float:
            return w[i] * 2.0
        def main(uv: float2, points: Float2Array, more: Float2Array, weights: FloatArray) -> float4:
            a = centroid(points)
            b = centroid(more)
            c = centroid([uv, uv * 2.0])
            return float4(a + b + c, weight(weights, 1), weight(weights, 2))
        """, target: .computeImage(interface))
        let names = opNames(words)
        // Two array arguments and one list: three centroids; one weight.
        #expect(names.filter { $0.hasPrefix("centroid") }.count == 3)
        #expect(names.filter { $0.hasPrefix("weight") } == ["weight"])
        // The arrays are read from the argument buffer, not passed: besides
        // `main`'s `uv`, only the list and the int are parameters.
        #expect(words.count(.opFunctionParameter) == 3)
    }

    @Test("a module constant list indexes by a value only known at run time")
    func constantListDynamicIndex() throws {
        let words = try compileValid("""
        QUAD = [float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0)]
        def corners() -> float2x2:
            return float2x2(1.0, 2.0, 3.0, 4.0)
        def main(uv: float2) -> float4:
            k = int(uv.x * 3.0) % 3
            return float4(QUAD[k], corners()[k % 2])
        """)
        #expect(words.count(.opAccessChain) >= 2)
    }

    @Test("list parameters: wrong elements and returned lists of no fixed length are errors")
    func listParameterErrors() {
        compileError("""
        def f(xs: list[float2]) -> float:
            return xs[0].x
        def main(uv: float2) -> float4:
            return float4(f([float3(uv, 1.0)]))
        """, contains: "cannot convert", line: 4)
        compileError("""
        def f(xs: list[float2]) -> float:
            return xs[0].x
        def main(uv: float2) -> float4:
            return float4(f(uv))
        """, contains: "`f` parameter `xs` takes a `list[float2]`, got `float2`", line: 4)
        compileError("""
        def f(xs: list[float]) -> list[float]:
            return xs
        def main(uv: float2) -> float4:
            return float4(f([1.0])[0])
        """, contains: "cannot return a `list[float]`", line: 1)
    }

    @Test("derivatives and discard are fragment-only")
    func fragmentOnly() {
        for call in ["fwidth(uv.x)", "dfdx(uv.x)"] {
            do {
                _ = try PyShader.compile("def main(uv: float2) -> float4:\n    return float4(\(call))\n", target: .nucleantUI)
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
        try compileValid(port.source, target: .nucleantUI)
    }

    @Test("the liquid glass effects compile with their arguments and the backdrop")
    func liquidGlass() throws {
        let dir = examplesDirectory.appendingPathComponent("liquid_glass")
        let optical = try String(contentsOf: dir.appendingPathComponent("liquid-glass.py"), encoding: .utf8)
        try compileValid(optical, target: .computeImage(.nucleantUI(
            samplesContent: true, arguments: [("radius", .float), ("thickness", .float), ("inset", .float)])))
        let squircle = try String(contentsOf: dir.appendingPathComponent("liquid-glass-squircle.py"), encoding: .utf8)
        try compileValid(squircle, target: .computeImage(.nucleantUI(
            samplesContent: true, arguments: [("power", .float), ("blur", .float), ("noise", .float)])))
    }
}

func shadertoyPorts() throws -> [(name: String, source: String)] {
    let dir = examplesDirectory.appendingPathComponent("shadertoy/pyshader")
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".py") }.sorted()
    return try files.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
}
