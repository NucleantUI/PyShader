import Testing
import PyShader
import SpirvCore
@testable import Spirv2PyShader

/// PyShader -> SPIR-V -> PyShader -> SPIR-V: the decompiled source must be
/// accepted by the compiler and validate, and read like the original.
@Suite("PyShader round trips")
struct RoundTripTests {
    @Test("every fragment example decompiles and recompiles", arguments: try exampleSources())
    func example(_ example: (name: String, source: String)) throws {
        let words = try PyShader.compile(example.source).spirv
        let decompiled = try decompileAndRecompile(words)
        #expect(decompiled.entryPoint == "main")
        #expect(decompiled.source.contains("def main("))
        #expect(!decompiled.source.contains("py_main"))
    }

    @Test("the entry wrapper collapses into main with the interface's parameter names")
    func wrapper() throws {
        let words = try PyShader.compile("""
        def main(uv: float2, time: float) -> float4:
            return float4(uv, sin(time), 1.0)
        """).spirv
        let out = try decompileAndRecompile(words)
        #expect(out.source.contains("def main(uv: float2, time: float) -> float4:\n    return float4(uv, sin(time), 1.0)"))
        #expect(out.source.components(separatedBy: "def ").count == 2)
    }

    @Test("module variables come back at module level with `global` where they are assigned")
    func moduleVariables() throws {
        let words = try PyShader.compile("""
        cam = float3(0.0, 1.0, -3.0)
        hits = 0
        tint = float3(0.5) * 2.0

        def map(p: float3) -> float:
            global hits
            hits += 1
            return length(p - cam) - 1.0

        def main(uv: float2, time: float) -> float4:
            global tint
            tint.y = map(float3(uv, 0.0))
            return float4(tint, float(hits))
        """).spirv
        let s = try decompileAndRecompile(words).source
        // `cam` is never assigned, so it was inlined as a constant.
        #expect(s.contains("\nhits = 0\ntint = float3(0.5) * 2.0\n"))
        #expect(s.contains("def map(p: float3) -> float:\n    global hits\n    hits += 1\n    return length(p - float3(0.0, 1.0, -3.0)) - 1.0"))
        #expect(s.contains("def main(uv: float2, time: float) -> float4:\n    global tint\n    tint.y = map(float3(uv, 0.0))\n    return float4(tint, float(hits))"))
        #expect(!s.contains("py_globals") && !s.contains("globals()"))
    }

    @Test("match comes back as match; a break in a case comes back through its flag")
    func match() throws {
        let words = try PyShader.compile("""
        def shade(k: int) -> float3:
            match k:
                case 0:
                    return float3(1.0, 0.0, 0.0)
                case 1 | 2:
                    return float3(0.0, 1.0, 0.0)
                case _:
                    return float3(0.5)

        def main(uv: float2) -> float4:
            total = 0.0
            for i in range(6):
                match i:
                    case 1:
                        continue
                    case 4:
                        break
                total += 0.25
            return float4(shade(int(uv.x * 4.0)) * total, 1.0)
        """).spirv
        let s = try decompileAndRecompile(words).source
        #expect(s.contains("def shade(k: int) -> float3:\n    match k:\n        case 0:\n            return float3(1.0, 0.0, 0.0)\n        case 1 | 2:\n            return float3(0.0, 1.0, 0.0)\n        case _:\n            return float3(0.5)"))
        #expect(s.contains("        match i:\n            case 1:\n                continue\n            case 4:\n"))
        #expect(s.contains("break"))
    }

    @Test("helpers, loops, swizzle stores and augmented assignment come back as written")
    func statements() throws {
        let source = """
        def palette(t: float) -> float3:
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)))

        def main(uv: float2, time: float) -> float4:
            color = float4(0.0, 0.0, 0.0, 1.0)
            for i in range(4):
                color.rgb += palette(uv.x + float(i)) * 0.25
            color.rgb *= 0.5 + 0.5 * sin(time)
            if uv.y > 0.5 and uv.x < 0.5:
                color.a = 0.5
            return color
        """
        let out = try decompileAndRecompile(try PyShader.compile(source).spirv)
        #expect(out.source.contains("def palette(t: float) -> float3:"))
        #expect(out.source.contains("for i in range(4):"))
        #expect(out.source.contains("color.xyz += palette(uv.x + float(i)) * 0.25"))
        #expect(out.source.contains("color.xyz *= 0.5 + 0.5 * sin(time)"))
        #expect(out.source.contains("if uv.y > 0.5 and uv.x < 0.5:"))
        #expect(out.source.contains("color.w = 0.5"))
    }

    @Test("tuple returns unpack")
    func tuples() throws {
        let source = """
        def split(v: float2) -> tuple[float, float2]:
            return length(v), normalize(v)

        def main(uv: float2) -> float4:
            l, n = split(uv - 0.5)
            return float4(n, l, 1.0)
        """
        let out = try decompileAndRecompile(try PyShader.compile(source).spirv)
        #expect(out.source.contains("-> tuple[float, float2]:"))
        #expect(out.source.contains("l, n = split(uv - 0.5)"))
    }

    @Test("lists and while loops")
    func lists() throws {
        let source = """
        def main(uv: float2) -> float4:
            w: list[float] = [0.13, 0.07, 0.03]
            colors = [float4(0.0)] * 3
            x = 3.0
            while x >= 0.0:
                colors[1] += float4(w[int(x) % 3])
                x -= 1.5
            return colors[1]
        """
        let out = try decompileAndRecompile(try PyShader.compile(source).spirv)
        #expect(out.source.contains("w = [0.13, 0.07, 0.03]"))
        #expect(out.source.contains("colors = [float4(0.0)] * 3"))
        #expect(out.source.contains("while x >= 0.0:"))
        #expect(out.source.contains("x -= 1.5"))
    }

    @Test("optimised SPIR-V (SSA form with phis) decompiles too", .enabled(if: Tools.spirvOpt != nil, "spirv-opt not installed"))
    func optimised() throws {
        let source = try String(contentsOf: packageRoot.appendingPathComponent("Examples/plasma.py"), encoding: .utf8)
        guard let words = try Tools.optimize(try PyShader.compile(source).spirv) else { return }
        let out = try Spirv2PyShader.decompile(words)
        #expect(out.warnings.isEmpty)
        let recompiled = try PyShader.compile(out.source)
        if let result = try Tools.validate(recompiled.spirv) { #expect(result.isEmpty, "spirv-val: \(result)") }
        #expect(out.source.contains("def main(uv: float2, time: float, resolution: float2) -> float4:"))
        #expect(out.source.contains("cos("))
    }

    @Test("a compute module is refused with a clear message")
    func compute() throws {
        let words = try PyShader.compile("def main(uv: float2) -> float4:\n    return float4(uv, 0.0, 1.0)\n", target: .nucleantUI).spirv
        #expect(throws: Spirv2PyShaderError.self) { try Spirv2PyShader.decompile(words) }
        do {
            _ = try Spirv2PyShader.decompile(words)
        } catch let error as Spirv2PyShaderError {
            #expect(error.message.contains("fragment"))
        }
    }

    @Test("the refusal names every stage SpirvCore knows, and the number of one it doesn't")
    func stageNames() throws {
        let compute = try PyShader.compile("def main(uv: float2) -> float4:\n    return float4(uv, 0.0, 1.0)\n", target: .nucleantUI).spirv
        // The compute module with its entry point relabelled as another stage.
        func refusal(model: UInt32) throws -> String? {
            var words = compute
            var i = 5
            while words[i] & 0xFFFF != UInt32(SpirvOp.opEntryPoint.rawValue) { i += Int(words[i] >> 16) }
            words[i + 1] = model
            do {
                _ = try Spirv2PyShader.decompile(words)
            } catch let error as Spirv2PyShaderError {
                return error.message
            }
            return nil
        }
        #expect(try refusal(model: SpirvExecutionModel.glCompute.rawValue)?.hasSuffix("(module has: compute)") == true)
        #expect(try refusal(model: SpirvExecutionModel.vertex.rawValue)?.hasSuffix("(module has: vertex)") == true)
        #expect(try refusal(model: SpirvExecutionModel.geometry.rawValue)?.hasSuffix("(module has: geometry)") == true)
        #expect(try refusal(model: SpirvExecutionModel.taskEXT.rawValue)?.hasSuffix("(module has: taskEXT)") == true)
        #expect(try refusal(model: 4242)?.hasSuffix("(module has: execution model 4242)") == true)
    }

    @Test("an instruction without a result is refused by name, not read as a value", arguments: [
        (op: SpirvOp.opDemoteToHelperInvocation, operands: 0), (.opEmitVertex, 0), (.opMemoryBarrier, 2), (.opControlBarrier, 3),
    ])
    func noResult(_ instruction: (op: SpirvOp, operands: Int)) throws {
        var words = try PyShader.compile("def main(uv: float2) -> float4:\n    return float4(uv, 0.0, 1.0)\n").spirv
        // At the top of the first function's body.
        var i = 5
        while words[i] & 0xFFFF != UInt32(SpirvOp.opLabel.rawValue) { i += Int(words[i] >> 16) }
        i += Int(words[i] >> 16)
        words.insert(contentsOf: SpirvInstruction(instruction.op, Array(repeating: 1, count: instruction.operands)).words, at: i)
        let error = #expect(throws: Spirv2PyShaderError.self) { try Spirv2PyShader.decompile(words) }
        #expect(error?.message.contains("\(instruction.op) is not supported") == true, "\(error?.message ?? "")")
    }

    @Test("bytes decompile like words")
    func bytes() throws {
        let shader = try PyShader.compile("def main(uv: float2) -> float4:\n    return float4(uv, 0.0, 1.0)\n")
        let fromWords = try Spirv2PyShader.decompile(shader.spirv)
        let fromBytes = try Spirv2PyShader.decompile(shader.bytes)
        #expect(fromWords.source == fromBytes.source)
    }
}
