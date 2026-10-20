import Testing
@testable import PyShader

/// An entry point's parameter typed as a module class: read whole from one
/// std430 buffer, the host writing the fields at their offsets.
@Suite("Class input")
struct ClassInputTests {

    static let glow = """
    class Glow:
        intensity: float
        tint: float4

    def main(uv: float2, glow: Glow) -> float4:
        d = distance(uv, float2(0.5))
        return float4(glow.tint.xyz * glow.intensity * smoothstep(0.5, 0.0, d), 1.0)
    """

    private func validate(_ shader: CompiledShader, sourceLocation: SourceLocation = #_sourceLocation) throws {
        if let result = try Tools.validate(shader) {
            #expect(result.isEmpty, "spirv-val: \(result)", sourceLocation: sourceLocation)
        }
    }

    /// `(decoration operand, value)` of every `OpMemberDecorate … Offset`.
    private func offsets(_ words: SpirvWords) -> [UInt32] {
        words.instructions
            .filter { $0.opcode == SpirvOp.opMemberDecorate.rawValue && $0.operands[2] == SpirvDecoration.offset.rawValue }
            .map { $0.operands[3] }
    }

    private func bindings(_ words: SpirvWords) -> [UInt32] {
        words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.binding.rawValue }
            .map { $0.operands[2] }
            .sorted()
    }

    @Test("a compute shader reads its class from binding 3, at std430 offsets")
    func compute() throws {
        let shader = try PyShader.compile(Self.glow, target: .nucleantUI)
        try validate(shader)
        let words = SpirvWords(words: shader.spirv)
        #expect(bindings(words) == [0, 1, 3], "output, uniforms, input")
        #expect(words.instructions.contains {
            $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.bufferBlock.rawValue
        })
        // Uniforms 0/16/32, then — in either order — the input block's one
        // member at 0, and Glow: intensity at 0, the float4 on the next 16.
        #expect(offsets(words).suffix(3).sorted() == [0, 0, 16])
    }

    @Test("the binding is the interface's")
    func binding() throws {
        let shader = try PyShader.compile(Self.glow, target: .computeImage(ComputeImageInterface(inputBinding: 7)))
        try validate(shader)
        #expect(bindings(SpirvWords(words: shader.spirv)) == [0, 1, 7])
    }

    @Test("std430: a float3 is 16-aligned and 12 long; a class aligns to its widest field")
    func layout() {
        let v = ShaderType.structure(name: "V", members: [("a", .float), ("b", .float(3)), ("c", .float)])
        #expect(v.std430Offsets == [0, 16, 28])
        #expect(v.std430?.size == 32 && v.std430?.alignment == 16)

        let pair = ShaderType.structure(name: "P", members: [("x", .float), ("y", .float(2))])
        #expect(pair.std430Offsets == [0, 8])
        #expect(pair.std430?.size == 16 && pair.std430?.alignment == 8)

        #expect(ShaderType.array(.float(3), 4).std430?.size == 64, "a float3 list has a 16 stride")
        #expect(ShaderType.array(.float, 4).std430?.size == 16)
        #expect(ShaderType.matrix(.float(bits: 32), columns: 3, rows: 3).std430?.size == 48)

        let outer = ShaderType.structure(name: "O", members: [("s", .float), ("inner", pair)])
        #expect(outer.std430Offsets == [0, 8])

        #expect(ShaderType.bool.std430 == nil)
        #expect(ShaderType.half.std430 == nil)
        #expect(ShaderType.array(.matrix(.float(bits: 32), columns: 4, rows: 4), 2).std430 == nil)
    }

    @Test("a nested class is laid out too")
    func nested() throws {
        let shader = try PyShader.compile("""
        class Light:
            position: float2
            color: float3

        class Scene:
            count: float
            light: Light

        def main(uv: float2, scene: Scene) -> float4:
            return float4(scene.light.color * scene.count, 1.0)
        """, target: .nucleantUI)
        try validate(shader)
        // Scene: count 0, light 16 (Light aligns to its float3); Light:
        // position 0, color 16.
        let all = offsets(SpirvWords(words: shader.spirv))
        #expect(all.contains(16))
        #expect(all.count == 3 + 1 + 2 + 2)
    }

    @Test("both stages of a pair read the same input")
    func graphics() throws {
        let shader = try PyShader.compile("""
        class Glow:
            size: float
            tint: float4

        class V:
            position: float4
            uv: float2

        def vertex(vertex_index: int, glow: Glow) -> V:
            corner = float2(float((vertex_index << 1) & 2), float(vertex_index & 2))
            return V(position=float4(corner * glow.size - 1.0, 0.0, 1.0), uv=corner * 0.5)

        def fragment(uv: float2, glow: Glow) -> float4:
            return glow.tint * uv.x
        """, target: .nucleantUIGraphics)
        try validate(shader)
        #expect(bindings(SpirvWords(words: shader.spirv)) == [1, 3])
    }

    /// The vertex stage's class, taken whole instead of field by field —
    /// its position the fragment's own.
    @Test("the fragment stage takes the vertex stage's class")
    func varyingsWhole() throws {
        let shader = try PyShader.compile("""
        class V:
            position: float4
            uv: float2
            seed: float

        def vertex(vertex_index: int) -> V:
            corner = float2(float((vertex_index << 1) & 2), float(vertex_index & 2))
            return V(position=float4(corner - 1.0, 0.0, 1.0), uv=corner * 0.5, seed=0.25)

        def fragment(v: V) -> float4:
            return float4(v.uv, v.seed, 1.0)
        """, target: .nucleantUIGraphics)
        try validate(shader)
        let words = SpirvWords(words: shader.spirv)
        let builtIns = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.builtIn.rawValue }
            .map { $0.operands[2] }
        #expect(builtIns.contains(SpirvBuiltIn.fragCoord.rawValue))
        let locations = words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.location.rawValue }
            .map { $0.operands[2] }
        // Output colour 0; the two varyings out of the vertex stage and into
        // the fragment one at 0 and 1.
        #expect(locations.sorted() == [0, 0, 0, 1, 1])
    }

    @Test("what a class input refuses")
    func errors() {
        func refuses(_ source: String, target: ShaderTarget = .nucleantUI, _ needle: String, sourceLocation: SourceLocation = #_sourceLocation) {
            do {
                _ = try PyShader.compile(source, target: target)
                Issue.record("expected an error containing \"\(needle)\"", sourceLocation: sourceLocation)
            } catch let error as PyShaderError {
                #expect(error.message.contains(needle), "got: \(error)", sourceLocation: sourceLocation)
            } catch {
                Issue.record("unexpected error type: \(error)", sourceLocation: sourceLocation)
            }
        }
        refuses("""
        class Flags:
            on: bool

        def main(uv: float2, flags: Flags) -> float4:
            return float4(1.0)
        """, "cannot be read from a buffer")

        refuses("""
        class A:
            x: float

        class B:
            y: float

        def vertex(vertex_index: int, a: A) -> V:
            return V(position=float4(0.0))

        class V:
            position: float4

        def fragment(b: B) -> float4:
            return float4(b.y)
        """, target: .nucleantUIGraphics, "one input class")

        refuses(Self.glow, target: .computeImage(.nucleantUI(samplesContent: false, arguments: [("gain", .float)])),
                "both at binding 3")

        refuses(Self.glow, target: .nucleant, "needs the compute or graphics target")
    }

    @Test("arguments at another binding go beside it")
    func besideArguments() throws {
        var interface = ComputeImageInterface.nucleantUI(samplesContent: false, arguments: [("gain", .float)])
        interface.inputBinding = 5
        let shader = try PyShader.compile("""
        class Glow:
            tint: float4

        def main(uv: float2, gain: float, glow: Glow) -> float4:
            return glow.tint * gain
        """, target: .computeImage(interface))
        try validate(shader)
        #expect(bindings(SpirvWords(words: shader.spirv)) == [0, 1, 3, 5])
    }
}
