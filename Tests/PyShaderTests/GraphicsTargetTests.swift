import Foundation
import Testing
@testable import PyShader

@Suite("Graphics target (vertex + fragment)")
struct GraphicsTargetTests {
    /// One quad per instance, placed from a float array of (x, y, seed) triples.
    static let glow = """
    QUAD = [float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
            float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)]

    class Varyings:
        position: float4
        uv: float2
        seed: float

    def vertex(vertex_index: int, instance_index: int, touches: FloatArray, resolution: float2) -> Varyings:
        t = instance_index * 3
        quad = QUAD
        corner = quad[vertex_index]
        centre = float2(touches[t], touches[t + 1])
        side = float2(0.5 * resolution.y / resolution.x, 0.5)
        return Varyings(
            position=float4((centre + corner * side) * 2.0 - 1.0, 0.0, 1.0),
            uv=corner * 0.5 + 0.5,
            seed=touches[t + 2],
        )

    def fragment(uv: float2, seed: float, time: float) -> float4:
        d = distance(uv, float2(0.5))
        glow = smoothstep(0.5, 0.0, d)
        return float4(float3(mod(seed + time, 1.0)), glow)
    """

    static let touches: [(name: String, kind: ShaderArgumentKind)] = [("touches", .floatArray)]

    @Test("one module, two entry points, shared uniforms and argument buffer")
    func layout() throws {
        let shader = try PyShader.compile(Self.glow, target: .graphics(.nucleantSwiftUI(arguments: Self.touches)))
        #expect(shader.entryPoint == "fragment")
        #expect(shader.vertexEntryPoint == "vertex")
        if let result = try Tools.validate(shader) {
            #expect(result.isEmpty, "spirv-val: \(result)")
        }
        let words = SpirvWords(words: shader.spirv)
        let entries = words.instructions.filter { $0.opcode == SpirvOp.opEntryPoint.rawValue }
        #expect(entries.map(\.operands[0]) == [SpirvExecutionModel.vertex.rawValue, SpirvExecutionModel.fragment.rawValue])
        let modes = words.instructions.filter { $0.opcode == SpirvOp.opExecutionMode.rawValue }
        #expect(modes.count == 1 && modes[0].operands[1] == SpirvExecutionMode.originUpperLeft.rawValue)

        let builtIns = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.builtIn.rawValue }
            .map { $0.operands[2] }
        #expect(builtIns.sorted() == [
            SpirvBuiltIn.position.rawValue, SpirvBuiltIn.vertexIndex.rawValue, SpirvBuiltIn.instanceIndex.rawValue,
        ].sorted(), "no FragCoord: the fragment takes only varyings and time")

        let bindings = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.binding.rawValue }
            .map { $0.operands[2] }
        #expect(bindings.sorted() == [1, 3], "Uniforms at 1, ShaderArgs at 3 — declared once for both stages")

        // Varyings `uv` (0) and `seed` (1) out of the vertex, in to the fragment; fragColor at 0.
        let locations = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.location.rawValue }
            .map { $0.operands[2] }
        #expect(locations.sorted() == [0, 0, 0, 1, 1])
        #expect(words.has(.opFNegate), "position.y is flipped into Vulkan clip space")
    }

    @Test("fragment inputs, integer varyings are flat")
    func fragmentInputs() throws {
        let words = try compileValid("""
        class V:
            position: float4
            kind: int

        def vertex(vertex_index: int) -> V:
            return V(float4(0.0, 0.0, 0.0, 1.0), vertex_index)

        def fragment(kind: int, uv: float2, frag_coord: float2, pixel: int2, front_facing: bool, resolution: float2, mouse: float2) -> float4:
            return float4(uv, float(kind + pixel.x), 1.0) if front_facing else float4(frag_coord / resolution, mouse)
        """, target: .nucleantSwiftUIGraphics)
        let flats = words.instructions.filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.flat.rawValue }
        #expect(flats.count == 1)
        let builtIns = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.builtIn.rawValue }
            .map { $0.operands[2] }
        #expect(builtIns.contains(SpirvBuiltIn.fragCoord.rawValue))
        #expect(builtIns.contains(SpirvBuiltIn.frontFacing.rawValue))
    }

    @Test("a varying the fragment does not take is still written by the vertex")
    func unusedVarying() throws {
        let words = try compileValid("""
        class V:
            position: float4
            unused: float3
            uv: float2

        def vertex() -> V:
            v = V(float4(0.0), float3(1.0), float2(0.5))
            v.uv = v.uv * 2.0
            v.unused.y = 3.0
            return v

        def fragment(uv: float2) -> float4:
            return float4(uv, 0.0, 1.0)
        """, target: .nucleantSwiftUIGraphics)
        // Two outputs at 0 and 1, one input at 1, fragColor at 0.
        let locations = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.location.rawValue }
            .map { $0.operands[2] }
        #expect(locations.sorted() == [0, 0, 1, 1])
    }

    @Test("a varying may shadow a built-in fragment input")
    func shadowedInput() throws {
        let words = try compileValid("""
        class V:
            position: float4
            uv: float2

        def vertex() -> V:
            return V(float4(0.0), float2(0.5))

        def fragment(uv: float2, frag_coord: float2) -> float4:
            return float4(uv, frag_coord)
        """, target: .nucleantSwiftUIGraphics)
        // `uv` comes from the varying; `frag_coord` alone pulls in gl_FragCoord.
        let builtIns = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.builtIn.rawValue }
            .map { $0.operands[2] }
        #expect(builtIns.sorted() == [SpirvBuiltIn.position.rawValue, SpirvBuiltIn.fragCoord.rawValue])
    }

    @Test("structs are ordinary values: fields, helpers, tuples of them")
    func structValues() throws {
        try compileValid("""
        class Ray:
            origin: float3
            dir: float3

        class V:
            position: float4
            t: float

        def advance(r: Ray, t: float) -> Ray:
            return Ray(r.origin + r.dir * t, r.dir)

        def vertex(vertex_index: int) -> V:
            r = advance(Ray(dir=float3(0.0, 0.0, 1.0), origin=float3(0.0)), float(vertex_index))
            return V(float4(r.origin, 1.0), r.dir.z)

        def fragment(t: float) -> float4:
            return float4(t)
        """, target: .nucleantSwiftUIGraphics)
    }

    @Test("every graphics example compiles and validates", arguments: try graphicsExampleSources())
    func example(_ example: (name: String, source: String)) throws {
        let interface = GraphicsInterface.nucleantSwiftUI(arguments: [
            ("touches", .floatArray), ("glowSeconds", .float),
        ])
        try compileValid(example.source, target: .graphics(interface))
    }

    @Test("errors")
    func errors() {
        func compileError(_ source: String, contains needle: String, line: Int? = nil, arguments: [(name: String, kind: ShaderArgumentKind)] = [], sourceLocation: SourceLocation = #_sourceLocation) {
            do {
                _ = try PyShader.compile(source, target: .graphics(.nucleantSwiftUI(arguments: arguments)))
                Issue.record("expected an error containing \"\(needle)\"", sourceLocation: sourceLocation)
            } catch let error as PyShaderError {
                #expect(error.message.contains(needle), "got: \(error)", sourceLocation: sourceLocation)
                if let line { #expect(error.line == line, "got line \(String(describing: error.line))", sourceLocation: sourceLocation) }
            } catch {
                Issue.record("unexpected error type: \(error)", sourceLocation: sourceLocation)
            }
        }
        let fragment = "def fragment() -> float4:\n    return float4(1.0)\n"
        compileError(fragment, contains: "def vertex(...) -> Varyings")
        compileError("class V:\n    position: float4\n\ndef vertex() -> V:\n    return V(float4(0.0))\n", contains: "def fragment(...) -> float4")
        compileError("def vertex() -> float4:\n    return float4(0.0)\n" + fragment, contains: "class whose first field is the `float4` position", line: 1)
        compileError("class V:\n    uv: float2\n    position: float4\n\ndef vertex() -> V:\n    return V(float2(0.0), float4(0.0))\n" + fragment, contains: "must be a `float4`, not `float2`")
        compileError("class V:\n    position: float4\n    seed: float\n\ndef vertex() -> V:\n    return V(float4(0.0), 1.0)\n" + fragment, contains: "varying `seed` clashes", arguments: [("seed", .float)])
        compileError("class V:\n    position: float4\n\ndef vertex(uv: float2) -> V:\n    return V(float4(uv, 0.0, 1.0))\n" + fragment, contains: "not a shader input; available:")
        compileError("class V:\n    position: float4\n\ndef vertex() -> V:\n    return V(float4(0.0))\n\ndef fragment(vertex_index: int) -> float4:\n    return float4(1.0)\n", contains: "not a shader input")
        compileError("class V:\n    position: float4\n    x: float = 1.0\n\ndef vertex() -> V:\n    return V(float4(0.0), 1.0)\n" + fragment, contains: "cannot have a default value", line: 3)
        compileError("class V:\n    position: float4\n    def f(self):\n        pass\n\ndef vertex() -> V:\n    return V(float4(0.0))\n" + fragment, contains: "methods are not supported")
        compileError("class V:\n    position: float4\n\ndef vertex() -> V:\n    return V(float4(0.0), 1.0)\n" + fragment, contains: "has 1 field(s), got 2")
        compileError("class V:\n    position: float4\n\ndef vertex() -> V:\n    return V(pos=float4(0.0))\n" + fragment, contains: "has no field `pos`")
        compileError("class V:\n    position: float4\n    a: float\n\ndef vertex() -> V:\n    return V(float4(0.0))\n" + fragment, contains: "missing field `a`")
        compileError("class V:\n    position: float4\n\ndef vertex() -> V:\n    v = V(float4(0.0))\n    return V(v.pos)\n" + fragment, contains: "has no field `pos`", line: 6)
        compileError("class float4:\n    x: float\n\n" + fragment, contains: "built-in type name")
    }
}

func graphicsExampleSources() throws -> [(name: String, source: String)] {
    let dir = examplesDirectory.appendingPathComponent("graphics")
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".py") }.sorted()
    return try files.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
}
