# Swift API & CLI

## `PyShader.compile`

```swift
import PyShader

public enum PyShader {
    /// A fragment stage; `interface` defaults to NucleantVulkan's `NucleantShader` layout.
    static func compile(_ source: String, interface: FragmentInterface = .nucleant) throws -> CompiledShader
    /// Any target.
    static func compile(_ source: String, target: ShaderTarget) throws -> CompiledShader
}

public struct CompiledShader: Sendable {
    let spirv: [UInt32]            // little-endian words, magic first
    let entryPoint: String         // `pName` for the stage (the fragment stage's, for .graphics)
    let vertexEntryPoint: String?  // the vertex stage's, for .graphics
    var bytes: Data                // the same words as bytes, e.g. for a .spv file
}
```

The source may be indented as a block (as in a Swift multi-line string);
the shared indentation is stripped. Errors are `PyShaderError` values:

```swift
public struct PyShaderError: Error, CustomStringConvertible {
    let message: String
    let line: Int?          // 1-based Python line
    var description: String // "line 7: `main` parameter `foo` is not a shader input; available: …"
}
```

## `ShaderTarget`

```swift
public enum ShaderTarget {
    case fragment(FragmentInterface)
    case computeImage(ComputeImageInterface)
    case graphics(GraphicsInterface)

    static let nucleant: ShaderTarget                 // .fragment(.nucleant)
    static let nucleantSwiftUI: ShaderTarget          // .computeImage(.nucleantSwiftUI)
    static let nucleantSwiftUIGraphics: ShaderTarget  // .graphics(.nucleantSwiftUI)
}

public enum ShaderArgumentKind { case float, float2, float3, float4, floatArray }
```

`ComputeImageInterface.nucleantSwiftUI(samplesContent:arguments:)` and
`GraphicsInterface.nucleantSwiftUI(arguments:)` build the NucleantSwiftUI
layouts with a content sampler and an argument buffer; the structs' other
properties (`entryPoint`, `localSize`, `descriptorSet`, bindings, `inputs`)
are public for other pipelines. See [Targets](../targets/index.md).

## `pyshaderc`

```sh
swift run pyshaderc <input.py> [-o output.spv] [--target fragment|compute|graphics] [--content] [--arg name:kind]...
```

Writes `<input>.spv` next to the input unless `-o` is given and prints the
word count. Exit status 1 with the error on stderr when compilation fails,
2 for a usage error.

```sh
swift run pyshaderc Examples/plasma.py
swift run pyshaderc Examples/compute/effect_ripple.py --target compute --content
swift run pyshaderc Examples/graphics/instanced_glow.py --target graphics --arg touches:floatArray --arg glowSeconds:float
spirv-val --target-env vulkan1.0 Examples/plasma.spv
```

## In NucleantSwiftUI

| where | what |
|---|---|
| `ShaderFunction(pyshader:)` | a `Shader(...)` view or a `.shader(_:)` effect; compiled for `.computeImage` with `samplesContent` set for effects and the view's `ShaderArgument`s declared |
| `VertexShaderFunction(pyshader:)` | a `VertexShader(_:vertices:instances:arguments:)` view; compiled for `.graphics` |

A shader that fails to compile is reported on stderr as
`shader node build … failed: PyShader: line N: …` and its rect stays empty.
