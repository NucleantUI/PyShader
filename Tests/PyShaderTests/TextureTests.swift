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
        samplesContent: Bool = false,
        arguments: [(name: String, kind: ShaderArgumentKind)] = []
    ) -> ShaderTarget {
        .computeImage(.nucleantUI(
            samplesContent: samplesContent,
            contentIsTopDown: true,
            arguments: arguments,
            textures: textures
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
}
