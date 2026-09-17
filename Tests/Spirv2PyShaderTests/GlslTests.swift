import Testing
import PyShader
@testable import Spirv2PyShader

/// GLSL through glslang, then decompiled: what the plan is for. Skipped
/// without glslangValidator on the machine.
@Suite("GLSL via glslang", .enabled(if: Tools.glslang != nil, "glslangValidator not installed"))
struct GlslTests {
    @Test("every ShaderToy example decompiles to PyShader that compiles", arguments: try exampleSources("Examples/shadertoy/opengl", suffix: ".glsl"))
    func shaderToy(_ example: (name: String, source: String)) throws {
        guard let words = try Tools.compileGLSL(wrapShaderToy(example.source)) else { return }
        let out = try decompileAndRecompile(words)
        #expect(out.source.contains("def mainImage("))
        #expect(out.source.contains("def main(frag_coord: float4"))
    }

    @Test("out parameters become tuple returns and uniforms are threaded into helpers")
    func outParameters() throws {
        let glsl = wrapShaderToy("""
        struct Hit { float t; vec3 n; };

        float sdf(in vec3 p, float r) { p.x *= 2.0; return length(p) - r; }

        void trace(in vec3 ro, out Hit h) {
            h.t = 0.0;
            for (int i = 0; i < 8; ++i) {
                float d = sdf(ro, 1.0);
                if (d < 0.001) break;
                if (i == 3) continue;
                h.t += d * sin(iTime);
            }
            h.n = vec3(0, 1, 0);
        }

        void mainImage(out vec4 col, in vec2 fc) {
            vec2 p = (fc - 0.5 * iResolution.xy) / iResolution.y;
            Hit h;
            trace(vec3(p, 1.0), h);
            bool ok = h.t > 0.5 && p.x < 0.0;
            float k = ok ? 1.0 : 0.5;
            int n = int(p.x * 4.0) % 3;
            col = vec4(mix(vec3(0.2), h.n, k), 1.0) * float(n);
            col.rgb *= sin(iTime);
        }
        """)
        guard let words = try Tools.compileGLSL(glsl) else { return }
        let out = try decompileAndRecompile(words)
        let s = out.source
        #expect(s.contains("class Hit:\n    t: float\n    n: float3"))
        #expect(s.contains("def sdf(p: float3, r: float) -> float:\n    p.x *= 2.0\n    return length(p) - r"))
        #expect(s.contains("def trace(ro: float3, h: Hit, time: float) -> Hit:"))
        #expect(s.contains("for i in range(8):"))
        #expect(s.contains("break"))
        #expect(s.contains("continue"))
        #expect(s.contains("h.t += d * sin(time)"))
        #expect(s.contains("return h"))
        #expect(s.contains("h = trace(float3(p, 1.0), Hit(0.0, float3(0.0)), time)"))
        #expect(s.contains("1.0 if h.t > 0.5 and p.x < 0.0 else 0.5"))
        #expect(s.contains("int(p.x * 4.0) % 3"))
        #expect(s.contains("col.xyz *= sin(time)"))
        #expect(s.contains("return mainImage(float4(0.0), frag_coord.xy, time, resolution)"))
    }

    @Test("ternaries, discard, matrices and arrays")
    func expressions() throws {
        let glsl = wrapShaderToy("""
        mat2 rot(float a) { float s = sin(a), c = cos(a); return mat2(c, s, -s, c); }

        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            vec2 p = fragCoord / iResolution.xy;
            if (p.x < 0.1) discard;
            float w[3] = float[3](0.1, 0.2, 0.3);
            float acc = 0.0;
            for (int i = 0; i < 3; i++) acc += w[i] * (p.y > 0.5 ? 2.0 : 1.0);
            p = rot(iTime) * p;
            vec3 c = p.x > p.y ? vec3(p, acc) : vec3(acc);
            fragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
        }
        """)
        guard let words = try Tools.compileGLSL(glsl) else { return }
        let s = try decompileAndRecompile(words).source
        #expect(s.contains("def rot(a: float) -> float2x2:"))
        #expect(s.contains("discard()"))
        #expect(s.contains("w = [0.1, 0.2, 0.3]"))
        #expect(s.contains("for i in range(3):"))
        #expect(s.contains("2.0 if p.y > 0.5 else 1.0"))
        #expect(s.contains("p = rot(time) * p"))
        #expect(s.contains("saturate(float3(p, acc) if p.x > p.y else float3(acc))"))
    }

    @Test("unsigned constants above Int32.max and integer hashing")
    func unsignedConstants() throws {
        let glsl = wrapShaderToy("""
        uint hash(uint x) { x ^= x >> 16u; x *= 2654435769u; x ^= x >> 15u; return x; }

        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            uint h = hash(uint(fragCoord.x) + hash(uint(fragCoord.y)));
            float v = float(h & 0xFFFFu) / 65535.0;
            fragColor = vec4(vec3(v), 1.0);
        }
        """)
        guard let words = try Tools.compileGLSL(glsl) else { return }
        let s = try decompileAndRecompile(words).source
        #expect(s.contains("x *= 2654435769"))
        #expect(s.contains(") & 65535) / 65535.0"))
    }

    @Test("inputs the interface does not describe are reported and can be renamed")
    func unmapped() throws {
        let glsl = """
        #version 450
        layout(location = 0) in vec2 uv;
        layout(location = 3) in vec3 tint;
        layout(location = 0) out vec4 fragColor;
        layout(set = 0, binding = 0) uniform Params { float speed; } params;
        void main() { fragColor = vec4(uv * params.speed, tint.r, 1.0); }
        """
        guard let words = try Tools.compileGLSL(glsl) else { return }
        let plain = try Spirv2PyShader.decompile(words)
        #expect(plain.warnings.count == 2)
        #expect(plain.source.contains("def main(uv: float2, tint: float3, speed: float) -> float4:"))
        let renamed = try Spirv2PyShader.decompile(words, options: .init(renames: ["tint": "color3", "speed": "rate"]))
        #expect(renamed.warnings.isEmpty)
        #expect(renamed.source.contains("def main(uv: float2, color3: float3, rate: float) -> float4:"))
        #expect(renamed.source.contains("return float4(uv * rate, color3.x, 1.0)"))
    }
}
