//
//  FragmentInterface.swift
//  PyShader
//
//  Describes what the host pipeline feeds the fragment stage. `main`'s
//  parameters are matched by name against this table, so the Python side
//  never spells locations or push-constant offsets.
//

import SpirvCore

public struct FragmentInterface: Sendable {
    public enum InputBinding: Sendable, Hashable {
        case location(Int)
        case builtIn(FragmentBuiltIn)
    }

    public enum FragmentBuiltIn: Sendable, Hashable {
        case fragCoord
        case pointCoord
        case frontFacing

        public var spirv: SpirvBuiltIn {
            switch self {
            case .fragCoord: return .fragCoord
            case .pointCoord: return .pointCoord
            case .frontFacing: return .frontFacing
            }
        }
    }

    public struct Input: Sendable {
        public var name: String
        public var type: ShaderType
        public var binding: InputBinding
        public init(name: String, type: ShaderType, binding: InputBinding) {
            self.name = name
            self.type = type
            self.binding = binding
        }
    }

    public struct PushConstantMember: Sendable {
        public var name: String
        public var type: ShaderType
        public var offset: Int
        public init(name: String, type: ShaderType, offset: Int) {
            self.name = name
            self.type = type
            self.offset = offset
        }
    }

    public struct Output: Sendable {
        public var name: String
        public var type: ShaderType
        public var location: Int
        public init(name: String, type: ShaderType, location: Int) {
            self.name = name
            self.type = type
            self.location = location
        }
    }

    public var inputs: [Input]
    public var pushConstants: [PushConstantMember]
    public var pushConstantBlockName: String
    public var output: Output
    /// Name of the Python function used as the entry point and of the SPIR-V entry point.
    public var entryPoint: String

    public init(
        inputs: [Input],
        pushConstants: [PushConstantMember],
        pushConstantBlockName: String = "PushConstants",
        output: Output,
        entryPoint: String = "main"
    ) {
        self.inputs = inputs
        self.pushConstants = pushConstants
        self.pushConstantBlockName = pushConstantBlockName
        self.output = output
        self.entryPoint = entryPoint
    }

    /// Matches NucleantVulkan's `NucleantShader` pipeline: fullscreen quad, `vTexCoord` at
    /// location 0, `fragColor` at location 0, and `ShaderPushConstants {time, _pad, resolution, mouse}`.
    public static let nucleant = FragmentInterface(
        inputs: [
            .init(name: "uv", type: .float(2), binding: .location(0)),
            .init(name: "color", type: .float(4), binding: .location(1)),
            .init(name: "frag_coord", type: .float(4), binding: .builtIn(.fragCoord)),
            .init(name: "front_facing", type: .bool, binding: .builtIn(.frontFacing)),
        ],
        pushConstants: [
            .init(name: "time", type: .float, offset: 0),
            .init(name: "resolution", type: .float(2), offset: 8),
            .init(name: "mouse", type: .float(2), offset: 16),
        ],
        output: .init(name: "fragColor", type: .float(4), location: 0)
    )

    /// Every name `main` may take as a parameter.
    public var parameterNames: [String] {
        inputs.map(\.name) + pushConstants.map(\.name)
    }
}
