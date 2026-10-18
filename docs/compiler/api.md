# Swift API & CLI

## `PyShader.compile`

```swift
import PyShader

public enum PyShader {
    /// A fragment stage; `interface` defaults to NucleantVulkan's `NucleantShader` layout.
    static func compile(_ source: String, interface: FragmentInterface = .nucleant) throws -> CompiledShader
    /// Any target. `sourceFile` adds the `.py` file's name and every statement's line;
    /// `modules` is the site-packages folder its imports of other PyShader modules are in.
    static func compile(_ source: String, target: ShaderTarget, sourceFile: String? = nil, modules: URL? = nil) throws -> CompiledShader
    static func compile(_ source: String, target: ShaderTarget, sourceFile: String? = nil, modules: String?) throws -> CompiledShader
    /// A `.py` file: its name and lines carried along, its imports found in its
    /// folder, then in `modules` — by default the nearest `.venv`'s site-packages.
    static func compile(contentsOf file: URL, target: ShaderTarget, modules: URL? = nil) throws -> CompiledShader
    static func compile(contentsOf file: URL, target: ShaderTarget, modules: String?) throws -> CompiledShader
}

public struct CompiledShader: Sendable {
    let spirv: [UInt32]            // little-endian words, magic first
    let entryPoint: String         // `pName` for the stage (the fragment stage's, for .graphics)
    let vertexEntryPoint: String?  // the vertex stage's, for .graphics
    var bytes: Data                // the same words as bytes, e.g. for a .spv file
}
```

The source may be indented as a block (as in a Swift multi-line string);
the shared indentation is stripped.

With `sourceFile`, the module carries the file's name (`OpString`, which
`OpSource` points at) and an `OpLine` before each statement, so `spirv-val`,
RenderDoc and naga report Python lines. Without it the module has no line
information and is the same as before the option existed. Each imported
module file a compiled statement comes from gets its own `OpString`. Errors
are `PyShaderError` values:

```swift
public struct PyShaderError: Error, CustomStringConvertible {
    let message: String
    let line: Int?          // 1-based Python line
    let file: String?       // the imported module's file the line is in; nil for the shader itself
    var description: String // "line 7: `main` parameter `foo` is not a shader input; available: …"
                            // "noise/fbm.py, line 12: unknown function `nope`"
}
```

## `modules:`

The site-packages folder a shader's imports of other PyShader modules are
installed in — a `URL` or a path. Only the packages whose distribution
declares a `pyshader.modules` entry point can be imported from it, and the
folders its `.pth` files add (editable installs) are searched too; see
[Modules](../language/modules.md).
## `ShaderTarget`

```swift
public enum ShaderTarget {
    case fragment(FragmentInterface)
    case computeImage(ComputeImageInterface)
    case graphics(GraphicsInterface)

    static let nucleant: ShaderTarget                 // .fragment(.nucleant)
    static let nucleantUI: ShaderTarget          // .computeImage(.nucleantUI)
    static let nucleantUIGraphics: ShaderTarget  // .graphics(.nucleantUI)
}

public enum ShaderArgumentKind { case float, float2, float3, float4, floatArray, float2Array, float3Array, float4Array }

public struct ShaderTexture {
    init(name: String, binding: Int, isTopDown: Bool = true)
}
```

`ComputeImageInterface.nucleantUI(samplesContent:contentIsTopDown:arguments:textures:)`
and `GraphicsInterface.nucleantUI(samplesContent:contentIsTopDown:arguments:textures:)`
build the NucleantUI layouts: an optional content sampler, an argument
buffer, and a sampler per [named texture](../targets/compute.md#textures).
The structs' other properties (`entryPoint`, `localSize`, `descriptorSet`,
bindings, `inputs`) are public for other pipelines. See
[Targets](../targets/index.md).

## `pyshaderc`

```sh
swift run pyshaderc <input.py> [-o output.spv] [--target fragment|compute|graphics] [--content] [--arg name:kind]... [--site-packages dir]
```

Writes `<input>.spv` next to the input unless `-o` is given and prints the
word count. Imports are found in the input's folder, then in
`--site-packages` — by default the site-packages of the nearest `.venv`
above the input. The module carries the input's file name and source lines (see
`sourceFile` above). Exit status 1 with the error on stderr when compilation fails,
2 for a usage error.

```sh
swift run pyshaderc Examples/plasma.py
swift run pyshaderc Examples/compute/effect_ripple.py --target compute --content
swift run pyshaderc Examples/graphics/instanced_glow.py --target graphics --arg touches:floatArray --arg glowSeconds:float
spirv-val --target-env vulkan1.0 Examples/plasma.spv
```

## In NucleantUI

| where | what |
|---|---|
| `ShaderFunction(pyshader:)` | a `Shader(...)` view or a `.shader(_:)` effect; compiled for `.computeImage` with `samplesContent` set for effects and the view's `ShaderArgument`s and `textures:` declared |
| `VertexShaderFunction(pyshader:)` | a `VertexShader(_:vertices:instances:arguments:textures:)` view; compiled for `.graphics` |

A shader that fails to compile is reported on stderr as
`shader node build … failed: PyShader: line N: …` and its rect stays empty.
