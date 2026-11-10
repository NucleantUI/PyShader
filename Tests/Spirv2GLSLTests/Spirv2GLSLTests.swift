import Foundation
import Testing
import PyShader
@testable import Spirv2GLSL

private let examples: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Spirv2GLSLTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // package root
    .appendingPathComponent("Examples")

/// glslangValidator's complaints about `source` as a `stage` shader, "" when
/// it has none; nil when the tool is not installed. Without `#version`
/// glslang reads OpenGL ES 2's GLSL ES 1.00 (with -S and the ES profile).
private func glslang(_ source: String, _ stage: GLSLESStage) throws -> String? {
    guard let tool = ["/usr/local/bin/glslangValidator", "/opt/homebrew/bin/glslangValidator"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
        return nil
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spirv2glsl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent(stage == .vertex ? "shader.vert" : "shader.frag")
    try Data(("#version 100\n" + source).utf8).write(to: file)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = [file.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    p.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return p.terminationStatus == 0 ? "" : output
}

/// PyShader source compiled to SPIR-V, its fragment stage translated and checked by glslang.
@discardableResult
private func fragment(_ python: String, target: ShaderTarget = .fragment(.nucleant), options: GLSLESOptions = GLSLESOptions(), sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
    let spirv = try PyShader.compile(python, target: target).spirv
    let shader = try GLSLESTranslator(spirv: spirv, options: options).translate(stage: .fragment)
    if let complaints = try glslang(shader.source, .fragment) {
        #expect(complaints.isEmpty, "glslang:\n\(complaints)\n--- fragment ---\n\(shader.source)", sourceLocation: sourceLocation)
    }
    return shader.source
}

private func expectError(_ python: String, _ needle: String, line: Int, options: GLSLESOptions = GLSLESOptions(), sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        let spirv = try PyShader.compile(python, target: .fragment(.nucleant), sourceFile: "shader.py").spirv
        let shader = try GLSLESTranslator(spirv: spirv, options: options).translate(stage: .fragment)
        Issue.record("expected an error containing \"\(needle)\", got:\n\(shader.source)", sourceLocation: sourceLocation)
    } catch let error as Spirv2GLSLError {
        #expect(error.message.contains(needle), "got: \(error)", sourceLocation: sourceLocation)
        #expect(error.line == line, "line of: \(error)", sourceLocation: sourceLocation)
        #expect(error.file == "shader.py", "file of: \(error)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

/// GLSL 4.50 compiled to Vulkan SPIR-V by glslang, another compiler's SPIR-V; nil without the tool.
private func glslangSpirv(_ source: String, _ stage: GLSLESStage) throws -> [UInt32]? {
    guard let tool = ["/usr/local/bin/glslangValidator", "/opt/homebrew/bin/glslangValidator"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
        return nil
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spirv2glsl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent(stage == .vertex ? "in.vert" : "in.frag")
    let out = dir.appendingPathComponent("out.spv")
    try Data(source.utf8).write(to: file)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = ["-V", "-g", file.path, "-o", out.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        Issue.record("glslang: \(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")")
        return nil
    }
    let data = try Data(contentsOf: out)
    return data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
}

@Suite("SPIR-V to GLSL ES 1.00")
struct Spirv2GLSLTests {

    @Test("structs, match, tuples, lists, module variables, derivatives and discard")
    func language() throws {
        let glsl = try fragment("""
        class Hit:
            t: float
            n: float3

        WEIGHTS = [0.5, 0.3, 0.2]
        counter = 0.0

        def shade(h: Hit, k: int) -> float3:
            match k:
                case 0 | 1:
                    return h.n * h.t
                case 2:
                    return float3(h.t)
                case _:
                    return float3(0.0)

        def pair(x: float) -> tuple[float, float]:
            return x * 2.0, x + 1.0

        def total(xs: list[float]) -> float:
            s = 0.0
            for i in range(3):
                s += xs[i]
            return s

        def main(uv: float2, time: float) -> float4:
            global counter
            counter += 1.0
            h = Hit(uv.x, float3(uv, 1.0))
            a, b = pair(uv.x)
            c = shade(h, int(uv.y * 3.0) % 3)
            q = c.zyx if a > b else c
            for j in range(4):
                if float(j) > time:
                    break
                q += float3(WEIGHTS[j % 3])
            if dFdx(uv.x) > 10.0:
                discard()
            return float4(q.xy, total(WEIGHTS), 1.0).wzyx + float4(counter)
        """)
        #expect(glsl.contains("struct Hit {"))
        #expect(glsl.contains("if (t == 0 || t == 1) {"), "\(glsl)")
        #expect(glsl.contains("} else if (t == 2) {"))
        #expect(glsl.contains("float total(float "))
        #expect(glsl.contains("#extension GL_OES_standard_derivatives : enable"))
        #expect(glsl.contains("discard;"))
        #expect(glsl.contains("? c.zyx : c;"))
        #expect(glsl.contains("int(mod(float(j_2), 3.0))"))
    }

    @Test("another compiler's SPIR-V: glslang's vertex and fragment stages, linked by their varyings")
    func glslangPair() throws {
        guard let vertexSpirv = try glslangSpirv("""
            #version 450
            layout(location = 0) in vec2 a_position;
            layout(location = 1) in vec2 a_texcoord;
            layout(location = 0) out vec2 v_uv;
            layout(set = 0, binding = 0) uniform Frame { mat4 projection; float time; } frame;
            void main() {
                v_uv = a_texcoord;
                gl_Position = frame.projection * vec4(a_position + vec2(sin(frame.time)), 0.0, 1.0);
            }
            """, .vertex),
              let fragmentSpirv = try glslangSpirv("""
            #version 450
            layout(location = 0) in vec2 uv_in;
            layout(location = 0) out vec4 color;
            layout(set = 0, binding = 1) uniform sampler2D image;
            void main() {
                vec4 sum = vec4(0.0);
                for (int i = 0; i < 4; i++) {
                    sum += texture(image, uv_in + vec2(float(i) * 0.01, 0.0));
                }
                color = sum * 0.25;
            }
            """, .fragment) else { return }
        let vertex = try GLSLESTranslator(spirv: vertexSpirv).translate(stage: .vertex)
        let fragment = try GLSLESTranslator(spirv: fragmentSpirv).translate(stage: .fragment, varyingNames: vertex.varyingNames)
        #expect(vertex.source.contains("attribute vec2 a_position;"))
        #expect(vertex.source.contains("uniform mat4 projection;"))
        #expect(vertex.source.contains("uniform float time;"))
        #expect(vertex.source.contains("varying vec2 v_uv;"))
        #expect(vertex.source.contains("gl_Position = "))
        // Linked by location: the fragment stage's `uv_in` takes the vertex stage's name.
        #expect(fragment.source.contains("varying vec2 v_uv;"), "\(fragment.source)")
        #expect(fragment.source.contains("uniform sampler2D image;"))
        #expect(fragment.source.contains("texture2D(image, "))
        #expect(fragment.source.contains("for (int i_2 = 0; i_2 < 4; i_2++) {"), "\(fragment.source)")
        #expect(vertex.attributes.map(\.name) == ["a_position", "a_texcoord"])
        for (source, stage) in [(vertex.source, GLSLESStage.vertex), (fragment.source, .fragment)] {
            if let complaints = try glslang(source, stage) {
                #expect(complaints.isEmpty, "glslang:\n\(complaints)\n\(source)")
            }
        }
    }

    @Test("the problem reported is the first in the source")
    func firstError() {
        expectError("""
        def main(uv: float2) -> float4:
            a = isnan(uv.x)
            m = float2x3(1.0)
            return float4(0.0)
        """, "isnan", line: 2)
    }

    @Test("a fragment stage reads its varying and uniforms and writes gl_FragColor")
    func basic() throws {
        let glsl = try fragment("""
        def main(uv: float2, time: float) -> float4:
            return float4(uv, sin(time), 1.0)
        """)
        #expect(glsl.contains("varying vec2 "))
        #expect(glsl.contains("uniform float time;"))
        #expect(glsl.contains("gl_FragColor = "))
        #expect(glsl.contains("precision highp float;"))
    }

    @Test("a counting loop is an Appendix A for loop, its counter still right after it")
    func countingLoop() throws {
        let glsl = try fragment("""
        def main(uv: float2, time: float) -> float4:
            s = 0.0
            for i in range(1, 9, 2):
                if float(i) > time:
                    continue
                s += uv.x * float(i % 3)
            return float4(s + float(i))
        """)
        #expect(glsl.contains("for (int i_2 = 1; i_2 < 9; i_2 += 2) {"), "\(glsl)")
        #expect(glsl.contains("continue;"))
    }

    @Test("a loop with a run-time bound has no Appendix A form, unless asked for any loop")
    func runtimeBound() throws {
        let source = "def main(uv: float2, time: float) -> float4:\n    s = 0.0\n    for i in range(int(time)):\n        s += 1.0\n    return float4(s)\n"
        expectError(source, "Appendix A", line: 3)
        let glsl = try fragment(source, options: GLSLESOptions(loopsFollowAppendixA: false))
        #expect(glsl.contains("while (true) {"))
        #expect(glsl.contains("break;"))
    }

    @Test("what OpenGL ES 2 cannot express is an error at its Python line")
    func errors() {
        expectError("def main(uv: float2) -> float4:\n    k = int(uv.x) & 3\n    return float4(0.0)\n", "bitwise", line: 2)
        expectError("def main(uv: float2) -> float4:\n    u = uint(3)\n    return float4(float(u))\n", "unsigned", line: 2)
        expectError("def main(uv: float2) -> float4:\n    return float4(float(isnan(uv.x)))\n", "isnan", line: 2)
    }

    @Test("the fragment examples translate and validate", arguments: ["forward_color.py", "plan_example.py", "plasma.py"])
    func exampleTranslates(_ name: String) throws {
        let source = try String(contentsOf: examples.appendingPathComponent(name), encoding: .utf8)
        try fragment(source)
    }

    /// The same lines the old OpenGL ES 2 compiler stopped at.
    @Test("the examples needing what OpenGL ES 2 lacks stop at that line", arguments: [
        ("builtins.py", 13, "isnan"),
        ("control_flow.py", 40, "Appendix A"),
        ("lambdas_and_types.py", 8, "unsigned"),
        ("module_style.py", 20, "computed at run time"),
    ])
    func exampleRefused(_ example: (String, Int, String)) throws {
        let source = try String(contentsOf: examples.appendingPathComponent(example.0), encoding: .utf8)
        expectError(source, example.2, line: example.1)
    }
}
