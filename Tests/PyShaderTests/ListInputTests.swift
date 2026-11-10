import Testing
@testable import PyShader

/// An entry point's parameter typed as a list of a module class: the input
/// buffer holds the host's elements one after another at the class's std430
/// stride, and the body reads one at a time — `steps[i]`, `len(steps)`.
@Suite("List input")
struct ListInputTests {

    /// The vertex stage reading its own step by instance, as a step
    /// sequencer's pads do.
    static let vertexSteps = """
    QUAD = [float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
            float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)]

    class Step:
        color: float4
        flags: uint

    class V:
        position: float4
        color: float4

    def vertex(vertex_index: int, instance_index: int, steps: list[Step]) -> V:
        c = QUAD[vertex_index]
        return V(float4(c, 0.0, 1.0), steps[instance_index].color)

    def fragment(color: float4) -> float4:
        return color
    """

    static let computeSteps = """
    class Step:
        color: float4
        flags: uint

    def main(uv: float2, steps: list[Step]) -> float4:
        total = float4(0.0)
        for i in range(len(steps)):
            if (steps[i].flags & 1) != 0:
                total += steps[i].color
        return total
    """

    private func validate(_ shader: CompiledShader, sourceLocation: SourceLocation = #_sourceLocation) throws {
        if let result = try Tools.validate(shader) {
            #expect(result.isEmpty, "spirv-val: \(result)", sourceLocation: sourceLocation)
        }
    }

    private func bindings(_ words: SpirvWords) -> [UInt32] {
        words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.binding.rawValue }
            .map { $0.operands[2] }
            .sorted()
    }

    /// The value of every `OpDecorate … ArrayStride`.
    private func strides(_ words: SpirvWords) -> [UInt32] {
        words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.arrayStride.rawValue }
            .map { $0.operands[2] }
    }

    private func compile(_ source: String, target: ShaderTarget, sourceLocation: SourceLocation = #_sourceLocation) throws -> SpirvWords {
        let shader = try PyShader.compile(source, target: target)
        try validate(shader, sourceLocation: sourceLocation)
        return SpirvWords(words: shader.spirv)
    }

    @Test("the vertex stage reads its step by instance_index, from binding 3")
    func vertex() throws {
        let words = try compile(Self.vertexSteps, target: .nucleantUIGraphics)
        #expect(bindings(words) == [1, 3], "uniforms, input")
        #expect(words.count(.opTypeRuntimeArray) == 1)
        // Step: color at 0, flags at 16, 20 long and 16-aligned — 32 apart.
        #expect(strides(words).contains(32))
        #expect(words.has(.opArrayLength), "the index is clamped to the list's length")
        #expect(words.instructions.contains {
            $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.bufferBlock.rawValue
        })
    }

    /// The vertex stage hands the fragment the step's index; the fragment
    /// takes the vertex stage's class first, and the list beside it.
    @Test("the fragment stage takes the list beside the vertex stage's class")
    func fragment() throws {
        let words = try compile("""
        QUAD = [float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
                float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)]

        class Step:
            color: float4
            flags: uint

        class StepVertex:
            position: float4
            index: float

        def vertex(vertex_index: int, instance_index: int) -> StepVertex:
            c = QUAD[vertex_index] * 0.1
            return StepVertex(float4(c, 0.0, 1.0), float(instance_index))

        def fragment(v: StepVertex, steps: list[Step]) -> float4:
            return steps[int(v.index)].color
        """, target: .nucleantUIGraphics)
        #expect(bindings(words) == [1, 3])
        #expect(words.count(.opTypeRuntimeArray) == 1)
    }

    /// The step's index handed on as an `int`: flat out of the vertex stage
    /// as well as into the fragment one, which WGSL (naga, the web build)
    /// asks of both sides, and Vulkan of the input only.
    @Test("the step's index as an int varying is flat on both sides")
    func intIndex() throws {
        let words = try compile("""
        QUAD = [float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
                float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)]

        class Step:
            color: float4
            flags: uint

        class StepVertex:
            position: float4
            index: int

        def vertex(vertex_index: int, instance_index: int) -> StepVertex:
            c = QUAD[vertex_index] * 0.1
            return StepVertex(float4(c, 0.0, 1.0), instance_index)

        def fragment(v: StepVertex, steps: list[Step]) -> float4:
            return steps[v.index].color
        """, target: .nucleantUIGraphics)
        let flat = Set(words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.flat.rawValue }
            .map { $0.operands[0] })
        let storage = words.instructions
            .filter { $0.opcode == SpirvOp.opVariable.rawValue && flat.contains($0.operands[1]) }
            .map { $0.operands[2] }
            .sorted()
        #expect(storage == [SpirvStorageClass.input.rawValue, SpirvStorageClass.output.rawValue].sorted())
    }

    @Test("both stages of a pair read the same list")
    func bothStages() throws {
        let words = try compile("""
        class Step:
            color: float4
            size: float

        class V:
            position: float4
            index: int

        def vertex(vertex_index: int, instance_index: int, steps: list[Step]) -> V:
            corner = float2(float((vertex_index << 1) & 2), float(vertex_index & 2))
            return V(float4(corner * steps[instance_index].size - 1.0, 0.0, 1.0), instance_index)

        def fragment(index: int, steps: list[Step]) -> float4:
            return steps[index].color
        """, target: .nucleantUIGraphics)
        #expect(bindings(words) == [1, 3], "one buffer, both stages")
        #expect(words.count(.opTypeRuntimeArray) == 1)
    }

    @Test("a compute shader counts the list with len() and reads it from binding 3")
    func compute() throws {
        let words = try compile(Self.computeSteps, target: .nucleantUI)
        #expect(bindings(words) == [0, 1, 3], "output, uniforms, input")
        #expect(words.has(.opArrayLength))
        #expect(strides(words) == [32])
    }

    @Test("the binding is the interface's")
    func binding() throws {
        let words = try compile(Self.computeSteps, target: .computeImage(ComputeImageInterface(inputBinding: 7)))
        #expect(bindings(words) == [0, 1, 7])
    }

    @Test("the elements are the class's std430 stride apart", arguments: [
        ("x: float", UInt32(4)),
        ("p: float2\n    s: float", 16),
        ("p: float3\n    s: float", 16),
        ("c: float4\n    f: uint", 32),
        ("a: float\n    m: float4x4", 80),
        ("m: float3x3", 48),
    ])
    func stride(_ layout: (fields: String, stride: UInt32)) throws {
        let words = try compile("""
        class E:
            \(layout.fields)

        def main(uv: float2, items: list[E]) -> float4:
            return float4(float(len(items)))
        """, target: .nucleantUI)
        #expect(strides(words) == [layout.stride])
    }

    /// The index is clamped to the ends and the read is skipped when the
    /// list is empty, the element left zero: a class is no `OpSelect`
    /// operand in SPIR-V 1.0.
    @Test("a read is clamped, and guarded by a selection rather than an OpSelect")
    func clampedRead() throws {
        let words = try compile(Self.computeSteps, target: .nucleantUI)
        #expect(words.extInstCount(.sClamp) >= 1)
        #expect(words.has(.opSelectionMerge))
        #expect(words.has(.opConstantComposite), "the zero Step")
        let selects = words.instructions.filter { $0.opcode == SpirvOp.opSelect.rawValue }
        #expect(selects.isEmpty)
    }

    @Test("a uint index reads too")
    func uintIndex() throws {
        _ = try compile("""
        class Step:
            color: float4
            next: uint

        def main(uv: float2, steps: list[Step]) -> float4:
            return steps[steps[0].next].color
        """, target: .nucleantUI)
    }

    @Test("a helper takes the list, or a list literal of the same class")
    func helper() throws {
        let words = try compile("""
        class Step:
            color: float4
            flags: uint

        def lit(steps: list[Step], i: int) -> float4:
            return steps[i].color * float((steps[i].flags & 2) >> 1)

        def main(uv: float2, steps: list[Step]) -> float4:
            local = [Step(float4(1.0), uint(2)), Step(float4(0.5), uint(0))]
            return lit(steps, 3) + lit(local, 0)
        """, target: .nucleantUI)
        #expect(bindings(words) == [0, 1, 3])
        #expect(words.count(.opTypeRuntimeArray) == 1)
    }

    /// Resolving `list[Step]` is not only for the input: an annotated local
    /// of a class's list works on a target with no input buffer at all.
    @Test("a list of a class is a type anywhere")
    func annotation() throws {
        try compileValid("""
        class Step:
            color: float4
            on: bool

        def main(uv: float2) -> float4:
            steps: list[Step] = [Step(float4(1.0, 0.0, 0.0, 1.0), True), Step(float4(0.0), False)]
            k = int(uv.x * 2.0)
            return steps[k].color if steps[k].on else float4(0.0)
        """)
    }

    @Test("the step sequencer example compiles and validates")
    func example() throws {
        let file = examplesDirectory.appendingPathComponent("step_sequencer/step_sequencer.py")
        let words = try compile(try String(contentsOf: file, encoding: .utf8), target: .nucleantUIGraphics)
        #expect(bindings(words) == [1, 3])
        #expect(strides(words).contains(32))
    }

    @Test("what a list input refuses")
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

        def main(uv: float2, flags: list[Flags]) -> float4:
            return float4(1.0)
        """, "cannot be read from a buffer")

        refuses("""
        class Step:
            color: float4

        class Look:
            tint: float4

        def main(uv: float2, look: Look, steps: list[Step]) -> float4:
            return look.tint
        """, "one input class")

        refuses(Self.computeSteps, target: .computeImage(.nucleantUI(samplesContent: false, arguments: [("gain", .float)])),
                "both at binding 3")

        refuses(Self.computeSteps, target: .nucleant, "needs the compute or graphics target")

        refuses("""
        def main(uv: float2, colors: list[float4]) -> float4:
            return colors[0]
        """, "not a shader input")

        refuses("""
        def main(uv: float2, steps: list[Missing]) -> float4:
            return float4(0.0)
        """, "not a shader input")

        refuses("""
        class Step:
            color: float4

        def main(uv: float2, steps: list[Step]) -> float4:
            steps[0] = Step(float4(1.0))
            return float4(0.0)
        """, "can only index into a variable")

        refuses("""
        class Step:
            color: float4

        def main(uv: float2, steps: list[Step]) -> float4:
            copy = steps
            return float4(0.0)
        """, "cannot store a `list[Step]`")

        refuses("""
        class Step:
            color: float4

        def main(uv: float2, steps: list[Step]) -> float4:
            return steps[0.5].color
        """, "list index must be an integer")
    }

    /// Any type an entry point takes, a lambda takes too: the list input is
    /// a handle the lambda's instance reads through, as a `def` does.
    @Test("a lambda takes the list input")
    func lambdaListInput() throws {
        let words = try compile("""
        class Step:
            color: float4

        first = lambda s: s[0].color

        def main(uv: float2, steps: list[Step]) -> float4:
            return first(steps)
        """, target: .computeImage(.nucleantUI(samplesContent: false, arguments: [])))
        #expect(words.count(.opTypeRuntimeArray) == 1)
    }

    @Test("a lambda takes array arguments, one instance per array")
    func lambdaArrayArgument() throws {
        let words = try compile("""
        first = lambda a: a[0]

        def main(uv: float2, mins: FloatArray, maxs: FloatArray) -> float4:
            return float4(first(mins), first(maxs), 0.0, 1.0)
        """, target: .computeImage(.nucleantUI(samplesContent: false, arguments: [("mins", .floatArray), ("maxs", .floatArray)])))
        // `first` for `mins` and `first` for `maxs`, besides main and the wrapper.
        #expect(words.count(.opFunction) == 4)
    }
}
