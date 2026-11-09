import Foundation
import Testing
@testable import PyShader

/// glslangValidator on both stages, which takes a shader without `#version`
/// as GLSL ES 1.00; nil when the tool is not installed.
private func glslang(_ shader: GLES2Shader) throws -> String? {
    guard let tool = ["/usr/local/bin/glslangValidator", "/opt/homebrew/bin/glslangValidator"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
        return nil
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyshader-gles2-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let vertex = dir.appendingPathComponent("shader.vert"), fragment = dir.appendingPathComponent("shader.frag")
    try Data(shader.vertex.utf8).write(to: vertex)
    try Data(shader.fragment.utf8).write(to: fragment)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = [vertex.path, fragment.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    p.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return p.terminationStatus == 0 ? "" : output
}

/// Compiles for OpenGL ES 2 and checks both stages with glslang when it is there.
@discardableResult
private func compileES(_ source: String, target: ShaderTarget = .nucleant, modules: [String: String] = [:], sourceLocation: SourceLocation = #_sourceLocation) throws -> GLES2Shader {
    let shader = try PyShader.compileGLES2(source, target: target, modules: modules)
    if let result = try glslang(shader) {
        #expect(result.isEmpty, "glslang:\n\(result)\n--- fragment ---\n\(shader.fragment)", sourceLocation: sourceLocation)
    }
    return shader
}

private func expectESError(_ source: String, target: ShaderTarget = .nucleant, _ needle: String, line: Int, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        _ = try PyShader.compileGLES2(source, target: target)
        Issue.record("expected an error containing \"\(needle)\"", sourceLocation: sourceLocation)
    } catch let error as PyShaderError {
        #expect(error.message.contains(needle), "got: \(error)", sourceLocation: sourceLocation)
        #expect(error.line == line, "line of: \(error)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

private let compute = ShaderTarget.computeImage(.nucleantUI(samplesContent: true))

@Suite("OpenGL ES 2")
struct GLES2Tests {

    // MARK: Examples

    @Test("the examples OpenGL ES 2 can express compile and validate", arguments: [
        ("plasma.py", ShaderTarget.nucleant),
        ("forward_color.py", .nucleant),
        ("plan_example.py", .nucleant),
        ("compute/effect_ripple.py", .computeImage(.nucleantUI(samplesContent: true))),
        ("compute/effect_bloom.py", .computeImage(.nucleantUI(samplesContent: true, contentIsTopDown: true))),
    ])
    func examples(_ example: (String, ShaderTarget)) throws {
        let source = try String(contentsOf: examplesDirectory.appendingPathComponent(example.0), encoding: .utf8)
        let shader = try compileES(source, target: example.1)
        #expect(shader.fragment.contains("gl_FragColor = py_main("))
    }

    @Test("an example importing modules beside it")
    func imports() throws {
        let file = examplesDirectory.appendingPathComponent("imports/orbit.py")
        let shader = try PyShader.compileGLES2(contentsOf: file, target: compute)
        #expect(try glslang(shader) ?? "" == "")
        #expect(shader.fragment.contains("palette_ramp("))
        #expect(!shader.fragment.contains("palette.ramp"))
    }

    @Test("the examples it cannot express fail at the line that needs more", arguments: [
        ("builtins.py", 13, "isnan"),
        ("control_flow.py", 40, "`while`"),
        ("lambdas_and_types.py", 8, "unsigned"),
        ("module_style.py", 20, "computed at run time"),
    ])
    func unsupportedExamples(_ example: (String, Int, String)) throws {
        let source = try String(contentsOf: examplesDirectory.appendingPathComponent(example.0), encoding: .utf8)
        expectESError(source, example.2, line: example.1)
    }

    // MARK: The names the stages declare

    @Test("a fragment target reads the generated vertex stage's varyings and writes gl_FragColor")
    func fragmentInterface() throws {
        let shader = try compileES("""
            def main(uv: float2, color: float4, frag_coord: float4, time: float) -> float4:
                return color * float4(uv, frag_coord.x * 0.0 + sin(time), 1.0)
            """)
        #expect(shader.fragment.contains("varying vec2 v_uv;"))
        #expect(shader.fragment.contains("varying vec4 v_color;"))
        #expect(shader.fragment.contains("uniform float time;"))
        #expect(shader.fragment.contains("gl_FragColor = py_main(v_uv, v_color, gl_FragCoord, time);"))
        // A quad already in clip space, its color from an attribute.
        #expect(shader.vertex.contains("attribute vec2 a_position;"))
        #expect(shader.vertex.contains("attribute vec4 a_color;"))
        #expect(shader.vertex.contains("v_color = a_color;"))
        #expect(shader.vertex.contains("v_uv = a_texcoord;"))
        #expect(shader.vertex.contains("gl_Position = vec4(a_position.xy, 0.0, 1.0);"))
        #expect(!shader.vertex.contains("uniform"))
        #expect(shader.singleFile.hasPrefix("---VERTEX SHADER---\n"))
        #expect(shader.singleFile.contains("\n---FRAGMENT SHADER---\n"))
    }

    @Test("the vertex stage passes on only the varyings the fragment stage reads")
    func onlyReadVaryings() throws {
        let shader = try compileES("""
            def main(frag_coord: float4) -> float4:
                return float4(fract(frag_coord.x), 0.0, 0.0, 1.0)
            """)
        #expect(!shader.vertex.contains("varying"))
        #expect(!shader.vertex.contains("a_texcoord"))
        #expect(!shader.vertex.contains("a_color"))
        #expect(shader.vertex.contains("gl_Position = vec4(a_position.xy, 0.0, 1.0);"))
    }

    @Test("every name, the matrices and the color's source are options")
    func renamed() throws {
        let options = GLES2Options(
            positionAttribute: "vPosition", texcoordAttribute: "vTexCoords0",
            colorUniform: "color", opacityUniform: "opacity",
            positionMatrices: ["projection_mat", "modelview_mat"],
            uvVarying: "tex_coord0", colorVarying: "frag_color", contentSampler: "texture0"
        )
        let shader = try PyShader.compileGLES2("""
            def main(uv: float2, color: float4) -> float4:
                return color * float4(uv, 0.0, 1.0)
            """, target: .nucleant, options: options)
        #expect(try glslang(shader) ?? "" == "")
        for line in ["attribute vec2 vPosition;", "attribute vec2 vTexCoords0;", "uniform mat4 projection_mat;",
                     "uniform mat4 modelview_mat;", "uniform vec4 color;", "uniform float opacity;",
                     "frag_color = color * vec4(1.0, 1.0, 1.0, opacity);", "tex_coord0 = vTexCoords0;",
                     "gl_Position = projection_mat * modelview_mat * vec4(vPosition.xy, 0.0, 1.0);"] {
            #expect(shader.vertex.contains(line), "\(line)")
        }
        #expect(!shader.vertex.contains("attribute vec4"), "the color is the uniform, not an attribute")
        #expect(shader.fragment.contains("gl_FragColor = py_main(tex_coord0, frag_color);"))
        let effect = try PyShader.compileGLES2("""
            def main(uv: float2) -> float4:
                return layer(uv)
            """, target: compute, options: options)
        #expect(effect.fragment.contains("uniform sampler2D texture0;"))
        #expect(effect.fragment.contains("texture2D(texture0, "))
    }

    @Test("uvIsTopDown flips the texture coordinate the generated vertex stage passes on")
    func uvTopDown() throws {
        let source = """
            def main(uv: float2, frag_coord: float2, resolution: float2) -> float4:
                return float4(uv, frag_coord.x / resolution.x, 1.0)
            """
        let upright = try compileES(source, target: compute)
        #expect(upright.vertex.contains("v_uv = a_texcoord;"))
        let flipped = try PyShader.compileGLES2(source, target: compute, options: GLES2Options(uvIsTopDown: true))
        #expect(try glslang(flipped) ?? "" == "")
        #expect(flipped.vertex.contains("v_uv = vec2(a_texcoord.x, 1.0 - a_texcoord.y);"))
        // `frag_coord` follows `uv`; the fragment stage itself is the same.
        #expect(flipped.fragment == upright.fragment)
    }

    @Test("a graphics target's vertex stage takes the vertex attributes, its position through the matrices")
    func graphicsAttributes() throws {
        let options = GLES2Options(
            positionAttribute: "vPosition", texcoordAttribute: "vTexCoords0", colorAttribute: "vColor",
            positionMatrices: ["projection_mat", "modelview_mat"]
        )
        let shader = try PyShader.compileGLES2("""
            class V:
                position: float4
                st: float2
                tint: float4

            def vertex(position: float2, texcoord: float2, color: float4, time: float) -> V:
                wave = sin(position.x * 0.02 + time) * 20.0
                return V(float4(position.x, position.y + wave, 0.0, 1.0), texcoord, color)

            def fragment(st: float2, tint: float4) -> float4:
                return tint * float4(st, 0.0, 1.0)
            """, target: .graphics(.nucleantUI(arguments: [])), options: options)
        #expect(try glslang(shader) ?? "" == "")
        for line in ["attribute vec2 vPosition;", "attribute vec2 vTexCoords0;", "attribute vec4 vColor;",
                     "uniform mat4 projection_mat;", "uniform mat4 modelview_mat;", "uniform float time;",
                     "gl_Position = projection_mat * modelview_mat * pyt0.position;", "varying vec2 v_st;"] {
            #expect(shader.vertex.contains(line), "\(line)")
        }
        #expect(shader.vertex.contains("py_vertex(vPosition, vTexCoords0, vColor, time)"))
        #expect(!shader.fragment.contains("attribute"))
    }

    @Test("any vertex attributes, and a position of 3 floats, for a custom vertex format")
    func customAttributes() throws {
        let options = GLES2Options(
            positionAttribute: "v_pos", positionSize: 3,
            attributes: ["v_normal": .float3, "size": .float],
            positionMatrices: ["projection_mat", "modelview_mat"]
        )
        let shader = try PyShader.compileGLES2("""
            class V:
                position: float4
                light: float

            def vertex(position: float3, v_normal: float3, size: float, time: float) -> V:
                light = max(dot(normalize(v_normal), float3(0.0, 0.0, 1.0)), 0.0)
                return V(float4(position * size, 1.0), light)

            def fragment(light: float) -> float4:
                return float4(float3(light), 1.0)
            """, target: .graphics(.nucleantUI(arguments: [])), options: options)
        #expect(try glslang(shader) ?? "" == "")
        for line in ["attribute vec3 v_pos;", "attribute vec3 v_normal;", "attribute float size;",
                     "py_vertex(v_pos, v_normal, size, time)",
                     "gl_Position = projection_mat * modelview_mat * pyt0.position;"] {
            #expect(shader.vertex.contains(line), "\(line)")
        }
        // The generated vertex stage of the other targets takes the position's size too.
        let quad = try compileES("""
            def main(uv: float2) -> float4:
                return float4(uv, 0.0, 1.0)
            """, target: compute)
        #expect(quad.vertex.contains("vec4(a_position.xy, 0.0, 1.0)"))
        let quad3 = try PyShader.compileGLES2("def main(uv: float2) -> float4:\n    return float4(uv, 0.0, 1.0)\n", target: compute, options: GLES2Options(positionSize: 3))
        #expect(quad3.vertex.contains("attribute vec3 a_position;"))
        #expect(quad3.vertex.contains("gl_Position = vec4(a_position.xyz, 1.0);"))
    }

    @Test("attributes must fit: a float to float4, a free name, a graphics target, a position of 2 to 4 floats")
    func attributeMistakes() {
        let graphics = """
            class V:
                position: float4

            def vertex(position: float2) -> V:
                return V(float4(position, 0.0, 1.0))

            def fragment() -> float4:
                return float4(1.0)
            """
        for (source, target, options, needle) in [
            (graphics, ShaderTarget.graphics(.nucleantUI(arguments: [])), GLES2Options(attributes: ["time": .float]), "attribute `time` clashes"),
            (graphics, .graphics(.nucleantUI(arguments: [])), GLES2Options(attributes: ["w": .floatArray]), "an attribute is a float"),
            (graphics, .graphics(.nucleantUI(arguments: [])), GLES2Options(positionSize: 5), "`positionSize` is 2, 3 or 4"),
            ("def main(uv: float2) -> float4:\n    return float4(uv, 0.0, 1.0)\n", compute, GLES2Options(attributes: ["w": .float]), "only a graphics target"),
            (graphics, .graphics(.nucleantUI(arguments: [])), GLES2Options(positionSize: 3), "is a `float3` input, not `float2`"),
        ] {
            do {
                _ = try PyShader.compileGLES2(source, target: target, options: options)
                Issue.record("expected an error containing \(needle)")
            } catch let error as PyShaderError {
                #expect(error.message.contains(needle), "got: \(error)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test("the vertex attributes are vertex inputs, and OpenGL ES 2 ones")
    func attributesOnlyInTheVertexStage() throws {
        let module = """
            class V:
                position: float4

            def vertex(position: float2) -> V:
                return V(float4(position, 0.0, 1.0))

            def fragment(position: float2) -> float4:
                return float4(position, 0.0, 1.0)
            """
        expectESError(module, target: .graphics(.nucleantUI(arguments: [])), "is not a shader input", line: 7)
        // The SPIR-V graphics target has no vertex buffers to read them from.
        do {
            _ = try PyShader.compile("""
                class V:
                    position: float4

                def vertex(position: float2) -> V:
                    return V(float4(position, 0.0, 1.0))

                def fragment() -> float4:
                    return float4(1.0)
                """, target: .graphics(.nucleantUI(arguments: [])))
            Issue.record("expected an error")
        } catch let error as PyShaderError {
            #expect(error.message.contains("is not a shader input"), "got: \(error)")
        }
    }

    @Test("a name an option gives must be one GLSL lets a shader declare, and its own")
    func badNames() {
        for (options, needle) in [
            (GLES2Options(uvVarying: "gl_TexCoord"), "`uvVarying` `gl_TexCoord`"),
            (GLES2Options(contentSampler: "two words"), "`contentSampler` `two words`"),
            (GLES2Options(colorUniform: "vec4"), "`colorUniform` `vec4`"),
            (GLES2Options(uvVarying: "v", colorVarying: "v"), "both `v`"),
        ] {
            do {
                _ = try PyShader.compileGLES2("def main(uv: float2) -> float4:\n    return float4(uv, 0.0, 1.0)\n", target: .nucleant, options: options)
                Issue.record("expected an error containing \(needle)")
            } catch let error as PyShaderError {
                #expect(error.message.contains(needle), "got: \(error)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test("a shader's own name that an option takes is renamed")
    func optionNameTaken() throws {
        let shader = try compileES("""
            def v_uv(x: float) -> float:
                return x * 2.0

            def main(uv: float2) -> float4:
                return float4(v_uv(uv.x), 0.0, 0.0, 1.0)
            """)
        #expect(shader.fragment.contains("varying vec2 v_uv;"))
        #expect(shader.fragment.contains("float py_v_uv(float x)"))
    }

    @Test("a compute target is one fragment per pixel, its inputs uniforms")
    func computeInterface() throws {
        let target = ShaderTarget.computeImage(.nucleantUI(samplesContent: true, contentIsTopDown: true, arguments: [("gain", .float), ("tint", .float4)]))
        let shader = try compileES("""
            def main(uv: float2, frag_coord: float2, pixel: int2, time: float, frame: int, mouse: float2, gain: float, tint: float4) -> float4:
                c = layer(uv) * gain + tint
                return c + float4(frag_coord, float(pixel.x + frame), time + mouse.x) * 0.0
            """, target: target)
        for declaration in ["uniform sampler2D u_content;", "uniform vec2 resolution;", "uniform float time;", "uniform int frame;",
                            "uniform vec2 mouse;", "uniform float gain;", "uniform vec4 tint;", "varying vec2 v_uv;"] {
            #expect(shader.fragment.contains(declaration), "\(declaration)")
        }
        // `content-top-down` reads the texture upright.
        #expect(shader.fragment.contains("1.0 - "))
        #expect(shader.fragment.contains("= v_uv * resolution;"))
    }

    @Test("a graphics target writes gl_Position and the varyings")
    func graphicsInterface() throws {
        let target = ShaderTarget.graphics(.nucleantUI(arguments: [("size", .float)]))
        let shader = try compileES("""
            class V:
                position: float4
                shade: float

            def vertex(time: float, size: float) -> V:
                return V(float4(sin(time) * size, 0.0, 0.0, 1.0), 0.5)

            def fragment(shade: float, uv: float2) -> float4:
                return float4(shade, uv, 1.0)
            """, target: target)
        #expect(shader.vertex.contains("gl_Position = pyt0.position;"))
        #expect(shader.vertex.contains("varying float v_shade;"))
        #expect(shader.vertex.contains("uniform float size;"))
        #expect(!shader.vertex.contains("resolution"))
        #expect(shader.fragment.contains("varying float v_shade;"))
        #expect(shader.fragment.contains("gl_FragCoord.xy / resolution"))
    }

    @Test("Texture parameters are sampler2D uniforms, read y-up unless texturesAreTopDown")
    func transitionTextures() throws {
        // A transition between two images, `t` its progress.
        let shader = try compileES("""
            def main(uv: float2, t: float, tex_in: Texture, tex_out: Texture) -> float4:
                return mix(tex_out(uv), tex_in(uv), t)
            """, target: .computeImage(.nucleantUI(samplesContent: false, arguments: [("t", .float)])))
        for declaration in ["uniform float t;", "uniform sampler2D tex_in;", "uniform sampler2D tex_out;"] {
            #expect(shader.fragment.contains(declaration), "\(declaration)")
        }
        #expect(shader.fragment.contains("texture2D(tex_in, uv)"))
        #expect(shader.fragment.contains("texture2D(tex_out, uv)"))
        #expect(!shader.fragment.contains("1.0 - "))
        let topDown = try compileES("""
            def main(uv: float2, t: float, tex_in: Texture, tex_out: Texture) -> float4:
                return mix(tex_out(uv), tex_in(uv), t)
            """, target: .computeImage(.nucleantUI(samplesContent: false, arguments: [("t", .float)], texturesAreTopDown: true)))
        #expect(topDown.fragment.contains("1.0 - "))
    }

    // MARK: The language

    @Test("match, lists, tuples, swaps, module variables, lambdas and list functions")
    func language() throws {
        let shader = try compileES("""
            WEIGHTS = [0.25, 0.5, 0.25]
            count = 0
            scale = lambda x: x * 2.0

            def total(xs: list[float]) -> float:
                s = 0.0
                for i in range(len(xs)):
                    s += xs[i]
                return s

            def split(v: float2) -> tuple[float, float]:
                return v.x, v.y

            def main(uv: float2, time: float) -> float4:
                global count
                count += 1
                a, b = split(uv)
                a, b = b, a
                k = int(time)
                match k:
                    case 0 | 1:
                        a = 0.0
                    case 2:
                        b = 1.0
                    case _:
                        pass
                w = 0.0
                for i in range(3):
                    w += WEIGHTS[i]
                    if i == 1:
                        break
                return float4(a, b, total(WEIGHTS) + w, scale(float(count)))
            """)
        #expect(shader.fragment.contains("if (k == 0 || k == 1) {"))
        #expect(shader.fragment.contains("} else if (k == 2) {"))
        #expect(shader.fragment.contains("for (int i = 0; i < 3; i++)"))
        #expect(shader.fragment.contains("void py_globals()"))
        #expect(shader.fragment.contains("py_globals();"))
        #expect(shader.fragment.contains("float total(float xs[3])"))
    }

    @Test("elif, conditional values, structs by keyword, matrices, helpers")
    func more() throws {
        try compileES("""
            class Light:
                dir: float3
                power: float

            def main(uv: float2, time: float) -> float4:
                l = Light(power=2.0, dir=float3(0.0, 0.0, 1.0))
                m = float3x3(1.0)
                r = float2x2(float3x3(2.0))
                n = m * l.dir
                v = n.z if uv.x > 0.5 else -n.z
                if uv.y < 0.25:
                    v = round(v) + trunc(v)
                elif length(uv * r[0]) > sinh(time):
                    v = tanh(v)
                else:
                    v = abs(int(v)) + min(1, 2, 3) + clamp(v, 0, 1)
                for j in range(8, 0, -2):
                    v += float(j // 3) + float(j % 3) + mod(v, 2.0)
                return float4(v * l.power, outerProduct(uv, uv)[1], 1.0)
            """)
    }

    @Test("Python names GLSL keeps for itself are renamed")
    func reservedNames() throws {
        let shader = try compileES("""
            def sample(input: float2) -> float:
                return input.x

            def main(uv: float2) -> float4:
                output = sample(uv)
                length = 2.0
                texture = float3(length, output, 0.0)
                return float4(texture, 1.0)
            """)
        #expect(shader.fragment.contains("float py_sample(vec2 py_input)"))
        #expect(!shader.fragment.contains(" output ="))
    }

    @Test("dFdx through GL_OES_standard_derivatives, discard as a statement")
    func derivatives() throws {
        let shader = try compileES("""
            def main(uv: float2) -> float4:
                if uv.x < 0.1:
                    discard()
                return float4(fwidth(uv), dFdx(uv.x), 1.0)
            """)
        #expect(shader.fragment.contains("#extension GL_OES_standard_derivatives : enable"))
        #expect(shader.fragment.contains("discard;"))
    }

    // MARK: What OpenGL ES 2 cannot do

    @Test("what OpenGL ES 2 cannot express is an error at its line")
    func errors() {
        expectESError("def main(uv: float2) -> float4:\n    i = 0\n    while i < 3:\n        i += 1\n    return float4(0.0)\n", "`while`", line: 3)
        expectESError("def main(uv: float2) -> float4:\n    k = int(uv.x) & 3\n    return float4(0.0)\n", "bitwise", line: 2)
        expectESError("def main(uv: float2) -> float4:\n    k = ~int(uv.x)\n    return float4(0.0)\n", "bitwise", line: 2)
        expectESError("def main(uv: float2) -> float4:\n    u = uint(3)\n    return float4(0.0)\n", "unsigned", line: 2)
        expectESError("def main(uv: float2, time: float) -> float4:\n    s = 0.0\n    for i in range(int(time)):\n        s += 1.0\n    return float4(s)\n", "constant bounds", line: 3)
        expectESError("def main(uv: float2) -> float4:\n    xs = [1.0, 2.0]\n    k = int(uv.x)\n    return float4(xs[k])\n", "computed at run time", line: 4)
        expectESError("def main(uv: float2) -> float4:\n    for i in range(3):\n        i = 2\n    return float4(0.0)\n", "counter", line: 3)
        expectESError("def main(uv: float2) -> float4:\n    for i in range(3):\n        pass\n    return float4(float(i))\n", "counter of a loop above", line: 4)
        expectESError("def main(uv: float2) -> float4:\n    m = float2x3(1.0)\n    return float4(0.0)\n", "square", line: 2)
        expectESError("def main(uv: float2) -> float4:\n    return float4(float(isnan(uv.x)))\n", "isnan", line: 2)
        expectESError("pair = lambda x: [x, x]\n\ndef main(uv: float2) -> float4:\n    return float4(pair(uv.x)[0])\n", "functions cannot return arrays", line: 1)
    }

    @Test("target inputs OpenGL ES 2 has no counterpart for")
    func unsupportedInputs() {
        expectESError("def main(uv: float2, mins: FloatArray) -> float4:\n    return float4(0.0)\n",
                      target: .computeImage(.nucleantUI(samplesContent: false, arguments: [("mins", .floatArray)])),
                      "array argument `mins`", line: 1)
        expectESError("""
            class V:
                position: float4

            def vertex(vertex_index: int) -> V:
                return V(float4(0.0))

            def fragment() -> float4:
                return float4(1.0)
            """, target: .nucleantUIGraphics, "vertex index", line: 4)
        expectESError("""
            class Step:
                level: float

            def main(uv: float2, step: Step) -> float4:
                return float4(step.level)
            """, target: .nucleantUI, "storage buffer", line: 4)
    }
}
