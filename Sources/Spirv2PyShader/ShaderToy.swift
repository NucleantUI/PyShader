//
//  ShaderToy.swift
//  Spirv2PyShader
//
//  The layout ShaderToy code is compiled against before it is decompiled.
//  Its names are the compute target's (`frag_coord` as a float2, `mouse`,
//  `mouse_click`, `frame`, `time_delta`), so the PyShader that comes back is
//  what the hand ports look like and runs as a NucleantSwiftUI `Shader`
//  and in the docs' previews without edits.
//

import PyShader

extension FragmentInterface {
    /// The interface `ShaderToy.wrap` compiles a `mainImage` against.
    public static let shaderToy = FragmentInterface(
        inputs: [
            .init(name: "frag_coord", type: .float(2), binding: .location(0)),
        ],
        pushConstants: [
            .init(name: "time", type: .float, offset: 0),
            .init(name: "time_delta", type: .float, offset: 4),
            .init(name: "resolution", type: .float(2), offset: 8),
            .init(name: "mouse", type: .float(2), offset: 16),
            .init(name: "mouse_click", type: .float(2), offset: 24),
            .init(name: "frame", type: .int, offset: 32),
        ],
        output: .init(name: "fragColor", type: .float(4), location: 0)
    )
}

public enum ShaderToy {
    /// GLSL that declares `FragmentInterface.shaderToy` and ShaderToy's names
    /// on top of it. `#line 1` keeps glslang's line numbers those of the
    /// text that follows.
    public static let prelude = """
    #version 450
    layout(location = 0) in vec2 frag_coord;
    layout(location = 0) out vec4 fragColor;
    layout(push_constant) uniform PushConstants {
        float time; float time_delta; vec2 resolution; vec2 mouse; vec2 mouse_click; int frame;
    } pc;
    #define iTime pc.time
    #define iTimeDelta pc.time_delta
    #define iResolution pc.resolution
    #define iMouse vec4(pc.mouse, pc.mouse_click)
    #define iFrame pc.frame
    #line 1

    """

    /// The `main` that calls `mainImage`.
    public static let epilogue = "\nvoid main() { mainImage(fragColor, frag_coord); }\n"

    /// A complete fragment shader from ShaderToy-style GLSL (a `mainImage`).
    public static func wrap(_ source: String) -> String {
        prelude + source + epilogue
    }
}
