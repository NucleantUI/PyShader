//
//  ShaderTarget.swift
//  PyShader
//
//  Which pipeline the shader is compiled for. The Python side is the same
//  either way — `def main(uv, time, ...) -> float4` — only the wrapper the
//  compiler generates around it differs.
//

public enum ShaderTarget: Sendable {
    /// A fragment stage writing a colour attachment (NucleantVulkan's `VKShader`).
    case fragment(FragmentInterface)
    /// A compute stage writing one pixel per invocation into a storage image
    /// (NucleantVulkan's `OGLShaderNode`, as NucleantSwiftUI's `Shader` view uses it).
    case computeImage(ComputeImageInterface)
    /// A vertex stage and a fragment stage in one module, drawing into a colour
    /// attachment (NucleantVulkan's `VertFragShaderNode`, as NucleantSwiftUI's
    /// `VertexShader` view uses it).
    case graphics(GraphicsInterface)

    public static let nucleant: ShaderTarget = .fragment(.nucleant)
    public static let nucleantSwiftUI: ShaderTarget = .computeImage(.nucleantSwiftUI)
    public static let nucleantSwiftUIGraphics: ShaderTarget = .graphics(.nucleantSwiftUI)

    /// The entry point a single-stage target compiles; the fragment one for `.graphics`.
    var entryPoint: String {
        switch self {
        case .fragment(let i): return i.entryPoint
        case .computeImage(let i): return i.entryPoint
        case .graphics(let i): return i.fragmentEntryPoint
        }
    }

    /// Where the shader-argument buffer is bound, when the target has one.
    var argumentsBinding: (set: Int, binding: Int)? {
        switch self {
        case .fragment: return nil
        case .computeImage(let i): return i.argumentsBinding.map { (i.descriptorSet, $0) }
        case .graphics(let i): return i.argumentsBinding.map { (i.descriptorSet, $0) }
        }
    }
}

/// The kinds a `ShaderArgument` (a value handed to the shader from Swift) can have.
public enum ShaderArgumentKind: Sendable, Hashable {
    case float, float2, float3, float4
    /// A `float[]` of any length; `a[i]` reads (clamped to the ends), `len(a)` counts.
    case floatArray

    var type: ShaderType {
        switch self {
        case .float: return .float
        case .float2: return .float(2)
        case .float3: return .float(3)
        case .float4: return .float(4)
        case .floatArray: return .floatArray(argument: -1)
        }
    }

    var componentCount: Int {
        switch self {
        case .float: return 1
        case .float2: return 2
        case .float3: return 3
        case .float4: return 4
        case .floatArray: return 0
        }
    }
}

/// The compute-shader contract of NucleantVulkan's `OGLShaderNode` / NucleantSwiftUI's
/// `ShaderPipeline`. Numbers are properties so a variant pipeline can adjust them; the
/// shape (one storage image, one `Uniforms` block, optional content sampler and
/// argument buffer) is what the wrapper generates code for.
public struct ComputeImageInterface: Sendable {
    /// What `main` may take as a parameter, and where the wrapper gets it.
    public enum Input: Sendable, Hashable {
        /// `float2` in [0, 1], y-up.
        case uv
        /// `float2` pixel centre, y-up (ShaderToy's `fragCoord`).
        case fragCoord
        /// `int2` store location, y-down as the image is laid out.
        case pixel
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
            case .frame: return .int
            }
        }
    }

    public var entryPoint: String
    public var localSize: (x: Int, y: Int)
    public var descriptorSet: Int
    /// `writeonly image2D` rgba8 the shader writes.
    public var outputBinding: Int
    /// `Uniforms { vec4 timeInfo; vec4 res; vec4 mouseInfo; }`, std140.
    public var uniformBinding: Int
    /// `sampler2D` of the view the effect is applied to; enables `layer(uv)`.
    public var contentBinding: Int?
    /// `readonly buffer { float data[]; }` holding the shader arguments, with an
    /// (offset, count) float pair per argument at the front. Needed when `arguments` is non-empty.
    public var argumentsBinding: Int?
    /// Values handed in from the host, in buffer order. Each becomes a `main` parameter.
    public var arguments: [(name: String, kind: ShaderArgumentKind)]
    /// Parameter name -> source. Names that are also arguments are an error.
    public var inputs: [String: Input]

    public init(
        entryPoint: String = "main",
        localSize: (x: Int, y: Int) = (8, 8),
        descriptorSet: Int = 0,
        outputBinding: Int = 0,
        uniformBinding: Int = 1,
        contentBinding: Int? = nil,
        argumentsBinding: Int? = nil,
        arguments: [(name: String, kind: ShaderArgumentKind)] = [],
        inputs: [String: Input] = ComputeImageInterface.defaultInputs
    ) {
        self.entryPoint = entryPoint
        self.localSize = localSize
        self.descriptorSet = descriptorSet
        self.outputBinding = outputBinding
        self.uniformBinding = uniformBinding
        self.contentBinding = contentBinding
        self.argumentsBinding = argumentsBinding
        self.arguments = arguments
        self.inputs = inputs
    }

    public static let defaultInputs: [String: Input] = [
        "uv": .uv,
        "frag_coord": .fragCoord,
        "pixel": .pixel,
        "time": .time,
        "time_delta": .timeDelta,
        "frame": .frame,
        "resolution": .resolution,
        "mouse": .mouse,
        "mouse_click": .mouseClick,
    ]

    /// NucleantSwiftUI's `Shader` view without content or arguments. Use
    /// `nucleantSwiftUI(samplesContent:arguments:)` for a `.shader(_:)` effect
    /// or a shader with `ShaderArgument`s.
    public static let nucleantSwiftUI = ComputeImageInterface()

    public static func nucleantSwiftUI(
        samplesContent: Bool,
        arguments: [(name: String, kind: ShaderArgumentKind)] = []
    ) -> ComputeImageInterface {
        ComputeImageInterface(
            contentBinding: samplesContent ? 2 : nil,
            argumentsBinding: arguments.isEmpty ? nil : 3,
            arguments: arguments
        )
    }

    public var parameterNames: [String] {
        inputs.keys.sorted() + arguments.map(\.name)
    }
}

/// What the frontend needs to know about one entry point, independent of the target.
struct EntrySignature {
    let entryPoint: String
    /// The type the entry point must return; `nil` when it is declared by the
    /// function's own annotation (a vertex stage returns whatever varyings
    /// struct the module defines).
    let outputType: ShaderType?
    var parameterTypes: [String: ShaderType]
    var parameterNames: [String]
    /// Whether `return` without a value forwards the `color` input (fragment stages).
    let forwardsColor: Bool

    init(entryPoint: String, outputType: ShaderType?, parameterTypes: [String: ShaderType], parameterNames: [String], forwardsColor: Bool) {
        self.entryPoint = entryPoint
        self.outputType = outputType
        self.parameterTypes = parameterTypes
        self.parameterNames = parameterNames
        self.forwardsColor = forwardsColor
    }

    /// Every entry point the target compiles, keyed by its Python name.
    static func all(for target: ShaderTarget) throws -> [String: EntrySignature] {
        switch target {
        case .fragment(let i):
            var types: [String: ShaderType] = [:]
            for input in i.inputs { types[input.name] = input.type }
            for pc in i.pushConstants { types[pc.name] = pc.type }
            let entry = EntrySignature(
                entryPoint: i.entryPoint, outputType: i.output.type,
                parameterTypes: types, parameterNames: i.parameterNames, forwardsColor: true
            )
            return [i.entryPoint: entry]
        case .computeImage(let i):
            var types: [String: ShaderType] = [:]
            for (name, input) in i.inputs { types[name] = input.type }
            try addArguments(i.arguments, to: &types)
            let entry = EntrySignature(
                entryPoint: i.entryPoint, outputType: .float(4),
                parameterTypes: types, parameterNames: i.parameterNames, forwardsColor: true
            )
            return [i.entryPoint: entry]
        case .graphics(let i):
            var vertexTypes: [String: ShaderType] = [:]
            var fragmentTypes: [String: ShaderType] = [:]
            for (name, input) in i.inputs {
                if input.inVertex { vertexTypes[name] = input.type }
                if input.inFragment { fragmentTypes[name] = input.type }
            }
            try addArguments(i.arguments, to: &vertexTypes)
            try addArguments(i.arguments, to: &fragmentTypes)
            return [
                i.vertexEntryPoint: EntrySignature(
                    entryPoint: i.vertexEntryPoint, outputType: nil,
                    parameterTypes: vertexTypes, parameterNames: i.parameterNames(vertex: true), forwardsColor: false
                ),
                i.fragmentEntryPoint: EntrySignature(
                    entryPoint: i.fragmentEntryPoint, outputType: .float(4),
                    parameterTypes: fragmentTypes, parameterNames: i.parameterNames(vertex: false), forwardsColor: true
                ),
            ]
        }
    }

    private static func addArguments(_ arguments: [(name: String, kind: ShaderArgumentKind)], to types: inout [String: ShaderType]) throws {
        for (index, arg) in arguments.enumerated() {
            if types[arg.name] != nil {
                throw PyShaderError("shader argument `\(arg.name)` clashes with a built-in input name")
            }
            types[arg.name] = arg.kind == .floatArray ? .floatArray(argument: index) : arg.kind.type
        }
    }
}
