import Foundation
import Testing
@testable import PyShader

/// Named textures: images the host binds alongside the content image, which
/// the module names, samples as `a(uv)` and measures as `a_size`.
@Suite("Named textures")
struct TextureTests {

    static let mix = """
    def main(uv: float2, blend: float, a: Texture, b: Texture) -> float4:
        return mix(a(uv), b(uv), blend)
    """

    static func interface(
        textures: [ShaderTexture],
        texturesAreTopDown: Bool = false,
        samplesContent: Bool = false,
        arguments: [(name: String, kind: ShaderArgumentKind)] = []
    ) -> ShaderTarget {
        .computeImage(.nucleantUI(
            samplesContent: samplesContent,
            contentIsTopDown: true,
            arguments: arguments,
            textures: textures,
            texturesAreTopDown: texturesAreTopDown
        ))
    }

    private func bindings(_ words: SpirvWords) -> [UInt32] {
        words.instructions
            .filter { $0.opcode == SpirvOp.opDecorate.rawValue && $0.operands[1] == SpirvDecoration.binding.rawValue }
            .map { $0.operands[2] }
            .sorted()
    }

    @Test("two named textures are sampled at their own bindings")
    func twoTextures() throws {
        let words = try compileValid(Self.mix, target: Self.interface(
            textures: [
                ShaderTexture(name: "a", binding: 4),
                ShaderTexture(name: "b", binding: 5),
            ],
            arguments: [("blend", .float)]
        ))
        // One sample per texture, with an explicit LOD — a compute stage has
        // no derivatives to take an implicit one from.
        #expect(words.count(.opImageSampleExplicitLod) == 2)
        #expect(words.has(.opTypeSampledImage))
        // 0 output, 1 uniforms, 3 arguments, 4 and 5 the textures. No 2: this
        // shader samples no content image.
        #expect(bindings(words) == [0, 1, 3, 4, 5])
    }

    /// The example in the README's "Textures" and docs/targets/compute.md.
    @Test("the documented texture example compiles")
    func documentedExample() throws {
        let words = try compileValid("""
        def main(uv: float2, blend: float, a: Texture, b: Texture) -> float4:
            s = float2(a_size)                     # pixel size, int2
            return mix(a(uv), b(uv + float2(1.0 / s.x, 0.0)), blend)
        """, target: Self.interface(
            textures: [ShaderTexture(name: "a", binding: 4), ShaderTexture(name: "b", binding: 5)],
            arguments: [("blend", .float)]
        ))
        #expect(words.count(.opImageSampleExplicitLod) == 2)
        #expect(words.count(.opImageQuerySizeLod) == 1)
    }

    @Test("a texture reads alongside layer()")
    func withContent() throws {
        let words = try compileValid("""
        def main(uv: float2, noise: Texture) -> float4:
            return layer(uv) * noise(uv)
        """, target: Self.interface(
            textures: [ShaderTexture(name: "noise", binding: 4)],
            samplesContent: true
        ))
        #expect(words.count(.opImageSampleExplicitLod) == 2)
        #expect(bindings(words) == [0, 1, 2, 4])
    }

    @Test("a_size queries the texture's own pixel size")
    func size() throws {
        let words = try compileValid("""
        def main(uv: float2, a: Texture) -> float4:
            s = float2(a_size)
            return a(uv + float2(1.0 / s.x, 0.0))
        """, target: Self.interface(textures: [ShaderTexture(name: "a", binding: 4)]))
        // A sampled image has to be unwrapped before it can be queried, and
        // queried at a level — unlike the output storage image, which
        // `OpImageQuerySize` serves directly.
        #expect(words.has(.opImage))
        #expect(words.count(.opImageQuerySizeLod) == 1)
        #expect(words.has(.opImageQuerySize), "the output image is still queried for the bounds check")
    }

    /// A `RenderTexture` is stored top-down, so `a(p)` flips y; an image
    /// already in shader space does not.
    @Test("isTopDown decides whether the read is flipped")
    func orientation() throws {
        let source = """
        def main(uv: float2, a: Texture) -> float4:
            return a(uv)
        """
        let topDown = try compileValid(source, target: Self.interface(
            textures: [ShaderTexture(name: "a", binding: 4, isTopDown: true)]
        ))
        let upright = try compileValid(source, target: Self.interface(
            textures: [ShaderTexture(name: "a", binding: 4, isTopDown: false)]
        ))
        #expect(topDown.count(.opFSub) == upright.count(.opFSub) + 1)
    }

    @Test("a texture is in the graphics target's fragment stage too")
    func graphics() throws {
        let words = try compileValid("""
        class Varyings:
            position: float4
            uv: float2

        def vertex(vertex_index: int) -> Varyings:
            x = -1.0 + 2.0 * float(vertex_index % 2)
            y = -1.0 + 2.0 * float(vertex_index // 2)
            return Varyings(float4(x, y, 0.0, 1.0), float2(x, y) * 0.5 + 0.5)

        def fragment(uv: float2, a: Texture) -> float4:
            return a(uv)
        """, target: .graphics(.nucleantUI(
            arguments: [],
            textures: [ShaderTexture(name: "a", binding: 4)]
        )))
        #expect(words.count(.opImageSampleExplicitLod) == 1)
        #expect(bindings(words) == [1, 4])
    }

    @Test("a texture read as a value says how to sample it")
    func notAValue() {
        do {
            _ = try PyShader.compile("""
            def main(uv: float2, a: Texture) -> float4:
                return a
            """, target: Self.interface(textures: [ShaderTexture(name: "a", binding: 4)]))
            Issue.record("expected an error")
        } catch let error as PyShaderError {
            #expect(error.message.contains("is a texture; sample it as `a(uv)`"), "got: \(error)")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("sampling takes exactly one coordinate")
    func arity() {
        do {
            _ = try PyShader.compile("""
            def main(uv: float2, a: Texture) -> float4:
                return a(uv, 1.0)
            """, target: Self.interface(textures: [ShaderTexture(name: "a", binding: 4)]))
            Issue.record("expected an error")
        } catch let error as PyShaderError {
            #expect(error.message.contains("sample it with one `float2`"), "got: \(error)")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("a texture cannot take an argument's or an input's name")
    func clashes() {
        for name in ["blend", "time"] {
            do {
                _ = try PyShader.compile("""
                def main(uv: float2) -> float4:
                    return float4(uv, 0.0, 1.0)
                """, target: Self.interface(
                    textures: [ShaderTexture(name: name, binding: 4)],
                    arguments: [("blend", .float)]
                ))
                Issue.record("expected an error for `\(name)`")
            } catch let error as PyShaderError {
                #expect(error.message.contains("clashes with a built-in input or argument name"), "got: \(error)")
            } catch {
                Issue.record("unexpected error type: \(error)")
            }
        }
    }

    @Test("a shader with no textures declares none")
    func noneDeclared() throws {
        let words = try compileValid("""
        def main(uv: float2) -> float4:
            return float4(uv, 0.0, 1.0)
        """, target: Self.interface(textures: []))
        #expect(!words.has(.opTypeSampledImage))
        #expect(bindings(words) == [0, 1])
    }

    // MARK: Bindings from the `Texture` parameters

    @Test("with none listed, the Texture parameters are the textures, bound from 4 in order, y-up")
    func inferred() throws {
        let inferred = try compileValid(Self.mix, target: Self.interface(textures: [], arguments: [("blend", .float)]))
        let listed = try PyShader.compile(Self.mix, target: Self.interface(
            textures: [ShaderTexture(name: "a", binding: 4, isTopDown: false), ShaderTexture(name: "b", binding: 5, isTopDown: false)],
            arguments: [("blend", .float)]
        ))
        #expect(inferred.words == listed.spirv)
        #expect(bindings(inferred) == [0, 1, 3, 4, 5])
    }

    @Test("inferred bindings follow the order the parameters are declared in")
    func inferredOrder() throws {
        let source = """
        def main(uv: float2, b: Texture, blend: float, a: Texture) -> float4:
            return mix(a(uv), b(uv), blend)
        """
        let inferred = try compileValid(source, target: Self.interface(textures: [], arguments: [("blend", .float)]))
        let listed = try PyShader.compile(source, target: Self.interface(
            textures: [ShaderTexture(name: "b", binding: 4, isTopDown: false), ShaderTexture(name: "a", binding: 5, isTopDown: false)],
            arguments: [("blend", .float)]
        ))
        #expect(inferred.words == listed.spirv)
    }

    @Test("a vertex + fragment module has one set, in the order the names first appear")
    func inferredGraphics() throws {
        let source = """
        class Varyings:
            position: float4
            uv: float2

        def vertex(vertex_index: int, height: Texture) -> Varyings:
            x = -1.0 + 2.0 * float(vertex_index % 2)
            y = -1.0 + 2.0 * float(vertex_index // 2)
            uv = float2(x, y) * 0.5 + 0.5
            return Varyings(float4(x, y, height(uv).x, 1.0), uv)

        def fragment(uv: float2, albedo: Texture, height: Texture) -> float4:
            return albedo(uv) * height(uv)
        """
        let inferred = try compileValid(source, target: .graphics(.nucleantUI(arguments: [])))
        let listed = try PyShader.compile(source, target: .graphics(.nucleantUI(
            arguments: [],
            textures: [ShaderTexture(name: "height", binding: 4, isTopDown: false), ShaderTexture(name: "albedo", binding: 5, isTopDown: false)]
        )))
        #expect(inferred.words == listed.spirv)
        #expect(bindings(inferred) == [1, 4, 5])
    }

    @Test("texturesAreTopDown reads the inferred textures top-down")
    func inferredTopDown() throws {
        let topDown = try compileValid(Self.mix, target: Self.interface(textures: [], texturesAreTopDown: true, arguments: [("blend", .float)]))
        let listed = try PyShader.compile(Self.mix, target: Self.interface(
            textures: [ShaderTexture(name: "a", binding: 4, isTopDown: true), ShaderTexture(name: "b", binding: 5, isTopDown: true)],
            arguments: [("blend", .float)]
        ))
        let upright = try PyShader.compile(Self.mix, target: Self.interface(textures: [], arguments: [("blend", .float)]))
        #expect(topDown.words == listed.spirv)
        #expect(topDown.words != upright.spirv)
    }

    @Test("firstTextureBinding is where the inferred bindings start")
    func inferredFirstBinding() throws {
        let words = try compileValid(Self.mix, target: .computeImage(ComputeImageInterface(
            argumentsBinding: 3, arguments: [("blend", .float)], firstTextureBinding: 6
        )))
        #expect(bindings(words) == [0, 1, 3, 6, 7])
    }

    @Test("an interface that lists its textures keeps its own bindings")
    func listedKept() throws {
        let words = try compileValid("""
        def main(uv: float2, noise: Texture) -> float4:
            return noise(uv)
        """, target: Self.interface(textures: [ShaderTexture(name: "noise", binding: 9)]))
        #expect(bindings(words) == [0, 1, 9])
    }

    // MARK: Textures passed to functions

    /// For each texture binding, the functions that load its sampler.
    private func readers(_ words: SpirvWords) -> [UInt32: Swift.Set<UInt32>] {
        let instructions = words.instructions
        var bindingOf: [UInt32: UInt32] = [:]   // variable id -> binding
        for i in instructions where i.opcode == SpirvOp.opDecorate.rawValue && i.operands[1] == SpirvDecoration.binding.rawValue {
            bindingOf[i.operands[0]] = i.operands[2]
        }
        var out: [UInt32: Swift.Set<UInt32>] = [:]
        var function: UInt32?
        for i in instructions {
            switch i.opcode {
            case SpirvOp.opFunction.rawValue: function = i.operands[1]
            case SpirvOp.opFunctionEnd.rawValue: function = nil
            case SpirvOp.opLoad.rawValue:
                if let function, let binding = bindingOf[i.operands[2]], binding >= 4 {
                    out[binding, default: []].insert(function)
                }
            default: break
            }
        }
        return out
    }

    @Test("a function takes a texture under its own name and samples the one handed to it")
    func helperOwnName() throws {
        let words = try compileValid("""
        def darken(t: Texture, p: float2) -> float4:
            return t(p) * 0.5

        def main(uv: float2, background: Texture) -> float4:
            return darken(background, uv)
        """, target: Self.interface(textures: []))
        #expect(words.count(.opImageSampleExplicitLod) == 1)
        #expect(bindings(words) == [0, 1, 4])
    }

    @Test("a function called with two textures is compiled once for each, reading its own")
    func helperPerTexture() throws {
        let words = try compileValid("""
        def get(t: Texture, p: float2) -> float4:
            return t(p)

        def main(uv: float2, a: Texture, b: Texture) -> float4:
            return get(a, uv) + get(b, uv) + get(a, uv * 0.5)
        """, target: Self.interface(textures: []))
        #expect(words.count(.opImageSampleExplicitLod) == 2)
        let r = readers(words)
        #expect(r[4]?.count == 1 && r[5]?.count == 1, "got \(r)")
        #expect(r[4] != r[5], "each instance reads its own texture")
    }

    @Test("a texture is passed on through nested functions, with t_size")
    func helperNested() throws {
        let words = try compileValid("""
        def sample(u: Texture, p: float2) -> float4:
            return u(p)

        def blur(t: Texture, p: float2) -> float4:
            d = float2(1.0) / float2(t_size)
            return (sample(t, p - d) + sample(t, p + d)) * 0.5

        def main(uv: float2, a: Texture, b: Texture) -> float4:
            return blur(a, uv) * blur(b, uv)
        """, target: Self.interface(textures: []))
        #expect(words.count(.opImageQuerySizeLod) == 2)
        let r = readers(words)
        #expect(r[4]?.count == 2 && r[5]?.count == 2, "got \(r)")
        #expect(r[4]!.isDisjoint(with: r[5]!))
    }

    @Test("a lambda takes textures and array arguments, one instance each")
    func lambdaHandles() throws {
        let words = try compileValid("""
        pick = lambda t, p: t(p)
        first = lambda arr: arr[0]

        def main(uv: float2, a: Texture, b: Texture, w: FloatArray, v: FloatArray) -> float4:
            return pick(a, uv) + pick(b, uv) * (first(w) + first(v))
        """, target: Self.interface(textures: [], arguments: [("w", .floatArray), ("v", .floatArray)]))
        #expect(words.count(.opImageSampleExplicitLod) == 2)
        let r = readers(words)
        #expect(r[4]?.count == 1 && r[5]?.count == 1 && r[4] != r[5], "got \(r)")
    }

    @Test("a texture parameter shadows a module function of its name")
    func helperShadows() throws {
        let words = try compileValid("""
        def blur(p: float2) -> float4:
            return float4(p, 0.0, 1.0)

        def apply(blur: Texture, p: float2) -> float4:
            return blur(p)

        def main(uv: float2, image: Texture) -> float4:
            return apply(image, uv)
        """, target: Self.interface(textures: []))
        #expect(words.count(.opImageSampleExplicitLod) == 1)
    }

    @Test("functions take textures in both stages of a graphics module")
    func helperGraphics() throws {
        let words = try compileValid("""
        class Varyings:
            position: float4
            uv: float2

        def lift(h: Texture, p: float2) -> float:
            return h(p).x

        def tint(t: Texture, p: float2) -> float4:
            return t(p) * 0.5

        def vertex(vertex_index: int, height: Texture) -> Varyings:
            p = float2(float(vertex_index % 2), float(vertex_index // 2))
            return Varyings(float4(p, lift(height, p), 1.0), p)

        def fragment(v: Varyings, image: Texture) -> float4:
            return tint(image, v.uv)
        """, target: .graphics(.nucleantUI(arguments: [], textures: [])))
        #expect(words.count(.opImageSampleExplicitLod) == 2)
        #expect(bindings(words).filter { $0 >= 4 } == [4, 5])
    }

    @Test("a function's Texture parameter takes only a texture")
    func helperWrongArgument() {
        do {
            _ = try PyShader.compile("""
            def get(t: Texture, p: float2) -> float4:
                return t(p)

            def main(uv: float2, a: Texture) -> float4:
                return get(uv, uv)
            """, target: Self.interface(textures: []))
            Issue.record("expected an error")
        } catch let error as PyShaderError {
            #expect(error.message.contains("parameter `t` takes a `Texture`, got `float2`"), "got: \(error)")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("a class of the module's own called Texture is a class, not a texture")
    func classNamedTexture() throws {
        let words = try compileValid("""
        class Texture:
            tint: float4

        def main(uv: float2, settings: Texture) -> float4:
            return settings.tint
        """, target: Self.interface(textures: []))
        #expect(!words.has(.opTypeSampledImage))
    }
}
