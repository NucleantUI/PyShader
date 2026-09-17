import Testing
@testable import PyShader

@Suite("Codegen")
struct CodegenTests {
    @Test("plan example lowers swizzle ops the expected way")
    func planExample() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            color = float4(1, 0, 0, 1)
            color.rgb *= 0.5
            color.rgb = color.rgb + 0.5
            color.r = color.r / 2
            return color
        """)
        #expect(words.count(.opVectorTimesScalar) == 1)
        #expect(words.count(.opFAdd) == 1)
        #expect(words.count(.opFDiv) == 1)
        #expect(words.count(.opAccessChain) == 1, "single-component write uses an access chain")
        #expect(words.count(.opVectorShuffle) >= 2, "multi-component writes merge with a shuffle")
        #expect(words.count(.opConvertSToF) == 0, "int literals fold into float constants")
        #expect(words.count(.opConstantComposite) == 2, "float4(1, 0, 0, 1) and the splat float3(0.5) are constants")
    }

    @Test("python integer semantics")
    func integerSemantics() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            a = -7 // 2
            b = -7 % 3
            c = 7 / 2
            d = 2 ** 3
            return float4(float(a), float(b), c, d)
        """)
        #expect(words.has(.opSMod))
        #expect(words.has(.opSDiv))
        #expect(words.count(.opFDiv) == 1, "true division")
        #expect(words.extInstCount(.pow) == 1)
    }

    @Test("lambdas are instantiated per argument type")
    func lambdas() throws {
        let words = try compileValid("""
        sq = lambda x: x * x
        def main(uv: float2) -> float4:
            a = sq(uv.x)
            b = sq(uv)
            c = sq(uv.y)
            return float4(b, a, c)
        """)
        // py_main + entry + two lambda instances (float, float2); the float one is reused.
        #expect(words.count(.opFunction) == 4)
        #expect(words.count(.opFunctionCall) == 4)
    }

    @Test("structured control flow")
    func controlFlow() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            c = 0.0
            for i in range(4):
                if i == 2:
                    continue
                if i == 3:
                    break
                c += 0.1
            while c < 1.0:
                c += 0.5
            if uv.x > 0.5:
                return float4(c)
            elif uv.y > 0.5:
                c = 0.0
            else:
                c = 1.0
            return float4(c)
        """)
        #expect(words.count(.opLoopMerge) == 2)
        #expect(words.count(.opSelectionMerge) == 4)
        #expect(words.count(.opReturnValue) == 2)
        #expect(!words.has(.opUnreachable))
    }

    @Test("dead code after return is emitted into an unreachable block")
    func deadCode() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            if uv.x > 0.5:
                return float4(1.0)
            else:
                return float4(0.0)
            x = 1.0
        """)
        #expect(words.has(.opUnreachable))
    }

    @Test("discard emits OpKill")
    func discard() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            if uv.x < 0.1:
                discard()
            return float4(uv, 0.0, 1.0)
        """)
        #expect(words.count(.opKill) == 1)
    }

    @Test("main without return forwards color")
    func forwardColor() throws {
        let words = try compileValid("""
        def main(color: float4, uv: float2):
            if uv.x > 0.5:
                return float4(color.rgb * 0.5, color.a)
        """)
        #expect(words.count(.opReturnValue) == 2)
    }

    @Test("push constants and inputs are wired by parameter name")
    func interfaceWiring() throws {
        let words = try compileValid("""
        def main(mouse: float2, uv: float2, time: float, frag_coord: float4) -> float4:
            return float4(uv + mouse, time, frag_coord.x)
        """)
        let entry = words.instructions.first { $0.opcode == SpirvOp.opEntryPoint.rawValue }!
        // model, function, "main\0" (2 words), then interface ids: fragColor, uv, frag_coord
        #expect(entry.operands.count == 2 + 2 + 3)
        let offsets = words.instructions
            .filter { $0.opcode == SpirvOp.opMemberDecorate.rawValue && $0.operands[2] == SpirvDecoration.offset.rawValue }
            .map { $0.operands[3] }
        #expect(offsets == [0, 8, 16])
        let builtIns = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.builtIn.rawValue }
            .map { $0.operands[2] }
        #expect(builtIns == [SpirvBuiltIn.fragCoord.rawValue])
    }

    @Test("16-bit types add capabilities")
    func capabilities() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            h = half2(uv)
            s: short = short(1)
            return float4(float2(h), float(s), 1.0)
        """)
        let caps = words.instructions.filter { $0.opcode == SpirvOp.opCapability.rawValue }.map { $0.operands[0] }
        #expect(caps.contains(SpirvCapability.float16.rawValue))
        #expect(caps.contains(SpirvCapability.int16.rawValue))
    }

    @Test("module constants inline and can reference each other")
    func globals() throws {
        let words = try compileValid("""
        RED = float3(1.0, 0.0, 0.0)
        DIM = RED * 0.25
        SCALE: float = 2.0
        def main(uv: float2) -> float4:
            return float4(DIM * SCALE, 1.0)
        """)
        #expect(words.has(.opVectorTimesScalar))
    }

    @Test("module variables: `global` makes a Private variable set before the entry point")
    func moduleVariables() throws {
        let source = """
        cam = float3(0.0, 1.0, -3.0)
        hits: int = 0
        K = 2.0
        tint = float3(0.5) * K

        def map(p: float3) -> float:
            global hits
            hits += 1
            return length(p - cam) - 1.0

        def setup(t: float):
            global cam
            cam.x = sin(t)
            cam = cam + float3(0.0, 0.0, tint.z)

        def main(uv: float2, time: float) -> float4:
            global tint
            setup(time)
            d = map(float3(uv, 0.0))
            tint.y = d
            return float4(tint, float(hits))
        """
        let words = try compileValid(source)
        let privates = words.instructions.filter { $0.opcode == SpirvOp.opVariable.rawValue && $0.operands[2] == SpirvStorageClass.private.rawValue }
        #expect(privates.count == 3)
        // `K` stays an inlined constant; `py_globals` initializes the rest and each wrapper calls it first.
        #expect(words.has(.opFunctionCall))
        _ = try compileValid(source, target: .computeImage(.nucleantSwiftUI(samplesContent: false)))
    }

    @Test("custom interface")
    func customInterface() throws {
        let interface = FragmentInterface(
            inputs: [.init(name: "st", type: .float(2), binding: .location(3))],
            pushConstants: [.init(name: "seconds", type: .float, offset: 0)],
            output: .init(name: "out_color", type: .float(4), location: 0),
            entryPoint: "pixel"
        )
        let words = try compileValid("""
        def pixel(st: float2, seconds: float) -> float4:
            return float4(st, seconds, 1.0)
        """, interface: interface)
        let locations = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.location.rawValue }
            .map { $0.operands[2] }
        #expect(locations.sorted() == [0, 3])
    }
}

@Suite("Source normalization")
struct NormalizationTests {
    @Test("indented block source (Swift multi-line literal) compiles")
    func dedent() throws {
        try compileValid("""
                PI = 3.14

                def main(uv: float2) -> float4:
                    if uv.x > 0.5:
                        return float4(PI)
                    return float4(0.0)
            """)
    }

    @Test("tabs and no trailing newline")
    func tabs() throws {
        try compileValid("\tdef main(uv: float2) -> float4:\n\t\treturn float4(uv, 0.0, 1.0)")
    }
}
