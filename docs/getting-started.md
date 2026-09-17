# Getting started

## Add the package

PyShader is a Swift package with one library product, `PyShader`, and one
executable, `pyshaderc`. It builds for macOS 14+ and iOS 17+.

```swift title="Package.swift"
dependencies: [
    .package(url: "https://github.com/NucleantUI/PyShader.git", branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "PyShader", package: "PyShader"),
    ]),
]
```

## Compile a shader

```swift
import PyShader

let source = """
    def main(uv: float2, time: float) -> float4:
        return float4(uv, 0.5 + 0.5 * sin(time), 1.0)
    """

let shader = try PyShader.compile(source)                             // fragment stage, NucleantVulkan's layout
let compute = try PyShader.compile(source, target: .nucleantSwiftUI)  // compute stage, NucleantSwiftUI's layout

shader.spirv        // [UInt32] for vkCreateShaderModule
shader.bytes        // the same words as Data, e.g. for a .spv file
shader.entryPoint   // "main"
```

Source embedded in a Swift multi-line string may be indented as a block; the
compiler strips the shared indentation. Errors are `PyShaderError` values
whose description reads `line 7: …` with the 1-based Python line.

## In NucleantSwiftUI

`ShaderFunction(pyshader:)` goes wherever a `ShaderFunction` goes:

```swift
import NucleantSwiftUI
import PyShader

Shader(ShaderFunction(pyshader: source))                    // a full-view shader
Text("Hello").shader(ShaderFunction(pyshader: effect))      // an effect over a view: layer(uv)
Shader(ShaderFunction(pyshader: tinted), arguments: [       // ShaderArguments by name
    .color("tint", .orange), .float("strength", 0.45),
])
VertexShader(VertexShaderFunction(pyshader: glow), vertices: 6, instances: n, arguments: […])
```

The [Compute](targets/compute.md) and [Graphics](targets/graphics.md) target
pages describe what `main` can take in each case.

## The command line

```sh
swift run pyshaderc shader.py -o shader.spv
swift run pyshaderc effect.py --target compute --content -o effect.spv
swift run pyshaderc glow.py --target graphics --arg touches:floatArray --arg glowSeconds:float
```

| flag | meaning |
|---|---|
| `--target fragment` (default) | NucleantVulkan's `NucleantShader` fragment layout |
| `--target compute` | NucleantSwiftUI's `Shader` view: a compute stage writing a storage image |
| `--target graphics` | NucleantSwiftUI's `VertexShader` view: vertex + fragment in one module |
| `--content` | the shader may call `layer()` (compute) |
| `--arg name:kind` | a `ShaderArgument`; kinds are `float` `float2` `float3` `float4` `floatArray` |

The output validates with `spirv-val --target-env vulkan1.0` and can be
shrunk further with `spirv-opt --target-env=vulkan1.0 -O`.

## Editor support

The repository is also the `pyshader` Python package: typed stubs for every
type and builtin, generated from the same table the compiler implements. With
it installed, `from pyshader import *` gives completion and type checking in
any Python editor; the compiler ignores the import.

```sh
uv pip install -e path/to/PyShader        # or: uv add --editable path/to/PyShader
```

## Try it here

The [Playground](playground.md) compiles what you type with the same compiler,
running as WebAssembly in your browser, and draws it with WebGPU. Each
[example](examples/index.md) page ends with its live result.
