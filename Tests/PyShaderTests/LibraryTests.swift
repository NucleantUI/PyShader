import Testing
@testable import PyShader

/// The library functions over GLSL.std.450 and core ops beyond the first set:
/// split/scale, packing, bit manipulation, outer products and derivative control.
@Suite("Library")
struct LibraryTests {
    @Test("modf and frexp return tuples; ldexp takes an int exponent")
    func splitAndScale() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            f, w = modf(uv.x * 3.5)
            fv, wv = modf(uv * 3.5)
            m, e = frexp(uv.y * 100.0)
            mv, ev = frexp(uv * 100.0)
            back = ldexp(m, e)
            backv = ldexp(mv, ev)
            twice = ldexp(uv, 1)
            return float4(f + w + fv.x + wv.y, back, backv.x + twice.y, float(e + ev.x))
        """)
        // Spelled with core ops: naga (the web build) cannot resolve ModfStruct / FrexpStruct.
        #expect(words.extInstCount(.modfStruct) == 0 && words.extInstCount(.frexpStruct) == 0)
        #expect(words.extInstCount(.trunc) == 2)
        #expect(words.count(.opBitcast) >= 4, "frexp reads the exponent from the bits")
        #expect(words.extInstCount(.ldexp) == 3)
    }

    @Test("frexp matches Python's math.frexp, subnormals and zero included", .enabled(if: Tools.spirvOpt != nil, "spirv-opt not installed"))
    func frexpValues() throws {
        // spirv-opt folds the bit arithmetic on constants; each lane packs m + e * 100.
        let shader = try PyShader.compile("""
        def main(uv: float2) -> float4:
            m, e = frexp(float4(8.0, -0.75, 1.0e-40, 0.0))
            return m + float4(e) * 100.0
        """)
        guard let folded = try Tools.optimize(shader) else { return }
        let values = folded.scalarConstants.map { Float(bitPattern: $0) }
        let tiny: Float = 1.0e-40   // subnormal: mantissa 0.5443..., exponent -132
        let expected: [Float] = [0.5 + 4 * 100, -0.75, tiny.significand / 2 + Float(Int(tiny.exponent) + 1) * 100]
        for value in expected {
            #expect(values.contains { abs($0 - value) < 1e-3 }, "\(value) in \(values)")
        }
    }

    @Test("pack and unpack, GLSL and Metal spellings")
    func packing() throws {
        let words = try compileValid("""
        def main(uv: float2, color: float4) -> float4:
            a = packUnorm4x8(color)
            b = pack_float_to_snorm4x8(color * 2.0 - 1.0)
            h = packHalf2x16(uv)
            c = packUnorm2x16(uv) ^ packSnorm2x16(uv) ^ pack_float_to_unorm2x16(uv)
            out = unpackUnorm4x8(a) + unpack_snorm4x8_to_float(b)
            out.xy += unpackHalf2x16(h) + unpackSnorm2x16(c) + unpack_unorm2x16_to_float(c)
            out.x += unpackUnorm4x8(0xFF00FF00).y
            return out
        """)
        #expect(words.extInstCount(.packUnorm4x8) == 1)
        #expect(words.extInstCount(.packSnorm4x8) == 1)
        #expect(words.extInstCount(.packHalf2x16) == 1)
        #expect(words.extInstCount(.packUnorm2x16) == 2)
        #expect(words.extInstCount(.unpackUnorm4x8) == 2)
        #expect(words.extInstCount(.unpackHalf2x16) == 1)
    }

    @Test("bit counting, reversing, extracting and inserting on int and uint")
    func bits() throws {
        let words = try compileValid("""
        def main(uv: float2, frag_coord: float4) -> float4:
            i = int(frag_coord.x)
            u = uint(frag_coord.y)
            v = int2(i, i + 1)
            n = bitCount(i) + bitCount(u) + bitCount(v).y
            p = popcount(u)
            r = bitfieldReverse(u) ^ reverse_bits(u)
            se = bitfieldExtract(i, 2, 3)
            ue = extract_bits(u, 4, 8)
            ins = bitfieldInsert(u, 5, 0, 4) | insert_bits(u, u, 8, 8)
            lsb = findLSB(i) + findLSB(v).x
            msb = findMSB(i) + findMSB(u) + findLSB(u)
            t = float(n + se + lsb + msb) + float(p + r + ue + ins)
            return float4(t * 0.001)
        """)
        #expect(words.count(.opBitCount) == 4)
        #expect(words.count(.opBitReverse) == 2)
        #expect(words.count(.opBitFieldSExtract) == 1)
        #expect(words.count(.opBitFieldUExtract) == 1)
        #expect(words.count(.opBitFieldInsert) == 2)
        #expect(words.extInstCount(.findILsb) == 3)
        #expect(words.extInstCount(.findSMsb) == 1)
        #expect(words.extInstCount(.findUMsb) == 1)
        #expect(words.count(.opBitcast) == 3, "bitCount / findLSB / findMSB of a uint are bitcast to int")
    }

    @Test("float bits reinterpret as int / uint and back")
    func bitcasts() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            h = floatBitsToUint(uv) * 747796405
            k = floatBitsToInt(uv.x) ^ 1
            one = uintBitsToFloat(0x3F800000)
            back = intBitsToFloat(k) + uintBitsToFloat(h.x)
            return float4(float2(h & 255) / 255.0, one, back)
        """)
        #expect(words.count(.opBitcast) == 5)
    }

    @Test func bitcastNeeds32BitFloat() {
        compileError("def main(uv: float2) -> float4:\n    return float4(float(floatBitsToUint(half(uv.x))))\n", contains: "needs a 32-bit float", line: 2)
    }

    @Test("16-bit integers widen to 32 bits for the bit instructions")
    func shortBits() throws {
        let words = try compileValid("""
        def main(uv: float2, frag_coord: float4) -> float4:
            s = short(frag_coord.x)
            return float4(float(bitCount(s) + findMSB(s)))
        """)
        #expect(words.count(.opBitCount) == 1)
        #expect(words.count(.opSConvert) >= 1)
    }

    @Test("outerProduct gives a len(r) x len(c) matrix")
    func outer() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            m = outerProduct(float3(uv, 1.0), uv)
            col: float3 = m[1]
            return float4(col, 1.0)
        """)
        #expect(!words.has(.opOuterProduct), "built from c * r[j] columns: naga types OpOuterProduct transposed")
        #expect(words.count(.opVectorTimesScalar) == 2)
    }

    @Test("fine and coarse derivatives request DerivativeControl; plain ones do not")
    func derivativeControl() throws {
        let plain = try compileValid("""
        def main(uv: float2) -> float4:
            return float4(dfdx(uv.x), dfdy(uv.y), fwidth(uv.x), 1.0)
        """)
        #expect(!plain.requires(.derivativeControl))

        let words = try compileValid("""
        def main(uv: float2) -> float4:
            a = dFdxFine(uv.x) + dfdx_fine(uv.y) + dFdyFine(uv.x) + dfdy_fine(uv.y)
            b = dFdxCoarse(uv.x) + dfdx_coarse(uv.y) + dFdyCoarse(uv.x) + dfdy_coarse(uv.y)
            c = fwidthFine(uv) + fwidth_coarse(uv)
            return float4(a, b, c)
        """)
        #expect(words.requires(.derivativeControl))
        #expect(words.count(.opDPdxFine) == 2)
        #expect(words.count(.opDPdyCoarse) == 2)
        #expect(words.count(.opFwidthFine) == 1)
        #expect(words.count(.opFwidthCoarse) == 1)
    }

    @Test("fine derivatives are fragment-only like the plain ones")
    func fineDerivativeInCompute() {
        #expect(throws: PyShaderError.self) {
            try PyShader.compile("def main(uv: float2) -> float4:\n    return float4(dFdxFine(uv.x))\n",
                                 target: .computeImage(.nucleantUI(samplesContent: false)))
        }
    }

    @Test func bitsNeedIntegers() {
        compileError("def main(uv: float2) -> float4:\n    return float4(float(bitCount(uv.x)))\n", contains: "bitCount() needs an integer", line: 2)
    }

    @Test func packNeedsMatchingVector() {
        compileError("def main(uv: float2) -> float4:\n    return float4(float(packUnorm4x8(uv)))\n", contains: "packUnorm4x8() needs a `float4`", line: 2)
    }

    @Test func unpackNeedsUint() {
        compileError("def main(uv: float2) -> float4:\n    return unpackUnorm4x8(uv.x)\n", contains: "needs a `uint`", line: 2)
    }

    @Test func outerProductNeedsVectors() {
        compileError("def main(uv: float2) -> float4:\n    m = outerProduct(uv.x, uv)\n    return float4(1.0)\n", contains: "two vectors", line: 2)
    }

    @Test func ldexpComponentMismatch() {
        compileError("def main(uv: float2) -> float4:\n    return float4(ldexp(uv, int3(1)), 0.0, 1.0)\n", contains: "as many components", line: 2)
    }
}
