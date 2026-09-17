//
//  GraphicsInterface.swift
//  PyShader
//
//  The vertex + fragment contract of NucleantVulkan's `VertFragShaderNode` /
//  NucleantSwiftUI's `VertexShader` view. One Python module defines both
//  stages and compiles to one SPIR-V module with two entry points:
//
//      class Varyings:
//          position: float4      # clip space, y-up; the first member is the position
//          uv: float2            # everything after it is interpolated into `fragment`
//
//      def vertex(vertex_index: int, instance_index: int) -> Varyings: ...
//      def fragment(uv: float2, time: float) -> float4: ...
//
//  There are no vertex buffers: the vertex stage is driven by
//  `vertex_index` / `instance_index` and reads what it needs from the same
//  `Uniforms` block and argument buffer the compute target uses, so the host
//  pipeline is the compute one with a graphics pipeline in place of the
//  dispatch. Shader space stays y-up as in the compute target — the wrapper
//  flips the position into Vulkan's y-down clip space, and `frag_coord` /
//  `uv` are flipped back.
//

public struct GraphicsInterface: Sendable {

    /// What the entry points may take as parameters, and which stage has it.
    public enum Input: Sendable, Hashable {
        // Vertex stage only.
        /// `int` — `gl_VertexIndex`.
        case vertexIndex
        /// `int` — `gl_InstanceIndex`.
        case instanceIndex

        // Fragment stage only.
        /// `float2` in [0, 1], y-up.
        case uv
        /// `float2` pixel centre, y-up.
        case fragCoord
        /// `int2` pixel, y-down as the image is laid out.
        case pixel
        /// `bool` — `gl_FrontFacing`.
        case frontFacing

        // Either stage, from the `Uniforms` block.
        /// `float` seconds.
        case time
        /// `float` seconds since the previous frame.
        case timeDelta
        /// `int` frame counter.
        case frame
        /// `float2` output size in pixels.
        case resolution
        /// `float2` pointer position, y-up.
        case mouse
        /// `float2` pointer position while pressed, y-up.
        case mouseClick

        var type: ShaderType {
            switch self {
            case .uv, .fragCoord, .resolution, .mouse, .mouseClick: return .float(2)
            case .pixel: return .int(2)
            case .time, .timeDelta: return .float
            case .frame, .vertexIndex, .instanceIndex: return .int
            case .frontFacing: return .bool
            }
        }

        var inVertex: Bool {
            switch self {
            case .uv, .fragCoord, .pixel, .frontFacing: return false
            default: return true
            }
        }

        var inFragment: Bool {
            switch self {
            case .vertexIndex, .instanceIndex: return false
            default: return true
            }
        }
    }

    public var vertexEntryPoint: String
    public var fragmentEntryPoint: String
    public var descriptorSet: Int
    /// `Uniforms { vec4 timeInfo; vec4 res; vec4 mouseInfo; }`, std140, read by both stages.
    public var uniformBinding: Int
    /// `readonly buffer { float data[]; }` holding the shader arguments, as the compute
    /// target has it. Needed when `arguments` is non-empty.
    public var argumentsBinding: Int?
    /// Values handed in from the host, in buffer order. Each may be a parameter of either stage.
    public var arguments: [(name: String, kind: ShaderArgumentKind)]
    /// Parameter name -> source. Names that are also arguments, or varyings, are an error.
    public var inputs: [String: Input]

    public init(
        vertexEntryPoint: String = "vertex",
        fragmentEntryPoint: String = "fragment",
        descriptorSet: Int = 0,
        uniformBinding: Int = 1,
        argumentsBinding: Int? = nil,
        arguments: [(name: String, kind: ShaderArgumentKind)] = [],
        inputs: [String: Input] = GraphicsInterface.defaultInputs
    ) {
        self.vertexEntryPoint = vertexEntryPoint
        self.fragmentEntryPoint = fragmentEntryPoint
        self.descriptorSet = descriptorSet
        self.uniformBinding = uniformBinding
        self.argumentsBinding = argumentsBinding
        self.arguments = arguments
        self.inputs = inputs
    }

    public static let defaultInputs: [String: Input] = [
        "vertex_index": .vertexIndex,
        "instance_index": .instanceIndex,
        "uv": .uv,
        "frag_coord": .fragCoord,
        "pixel": .pixel,
        "front_facing": .frontFacing,
        "time": .time,
        "time_delta": .timeDelta,
        "frame": .frame,
        "resolution": .resolution,
        "mouse": .mouse,
        "mouse_click": .mouseClick,
    ]

    /// NucleantSwiftUI's `VertexShader` view without arguments.
    public static let nucleantSwiftUI = GraphicsInterface()

    public static func nucleantSwiftUI(
        arguments: [(name: String, kind: ShaderArgumentKind)]
    ) -> GraphicsInterface {
        GraphicsInterface(
            argumentsBinding: arguments.isEmpty ? nil : 3,
            arguments: arguments
        )
    }

    func parameterNames(vertex: Bool) -> [String] {
        inputs.filter { vertex ? $0.value.inVertex : $0.value.inFragment }.keys.sorted()
            + arguments.map(\.name)
    }
}
