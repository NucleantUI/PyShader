# Targets

The Python side is the same for every target — `def main(...) -> float4`
runs per pixel — but the SPIR-V wrapper the compiler generates around it
differs: which execution model, which inputs, and where they are bound.

| Target | Swift | Stage | Host |
|---|---|---|---|
| [Fragment](fragment.md) | `.fragment(FragmentInterface)`, default `.nucleant` | one fragment stage over a fullscreen quad, push constants | NucleantVulkan's `NucleantShader` |
| [Compute](compute.md) | `.computeImage(ComputeImageInterface)`, `.nucleantSwiftUI` | one compute invocation per pixel writing a storage image, a `Uniforms` block, optional content sampler and argument buffer | NucleantVulkan's `OGLShaderNode`, as NucleantSwiftUI's `Shader` / `.shader(_:)` drive it |
| [Graphics](graphics.md) | `.graphics(GraphicsInterface)`, `.nucleantSwiftUIGraphics` | a vertex and a fragment stage in one module, no vertex buffers | NucleantVulkan's `VertFragShaderNode`, as NucleantSwiftUI's `VertexShader` drives it |

`main` (or `vertex` / `fragment` for graphics) takes what it needs by
parameter name. Names not in the target's table are an error that lists what
is available.

## Entry point inputs

| parameter | type | fragment | compute | graphics |
|---|---|---|---|---|
| `uv` | `float2` | `vTexCoord` (location 0) | `frag_coord / resolution`, y-up | fragment stage |
| `frag_coord` | `float4` / `float2` | `gl_FragCoord` | pixel centre, y-up | fragment stage |
| `pixel` | `int2` | — | store location, y-down | fragment stage |
| `time` `resolution` `mouse` | `float` `float2` `float2` | push constants | `Uniforms` block | both stages |
| `time_delta` `frame` `mouse_click` | `float` `int` `float2` | — | `Uniforms` block | both stages |
| `color` | `float4` | vertex colour, forwarded by a bare `return` | — | — |
| `front_facing` | `bool` | `gl_FrontFacing` | — | fragment stage |
| `vertex_index` `instance_index` | `int` | — | — | vertex stage |
| *ShaderArgument name* | `float` … `float4`, `FloatArray` | — | argument buffer | both stages |

Shader space is y-up with `(0, 0)` bottom-left, as ShaderToy has it; the
wrapper flips what needs flipping so `uv`, `frag_coord` and `mouse` agree
across targets. `pixel` is the raw store location.

## Interfaces are values

Each target takes an interface struct describing the host pipeline, so a
different Vulkan layout is a different value rather than a different
compiler. `FragmentInterface` lists inputs (locations or built-ins), push
constant members with offsets and the output location;
`ComputeImageInterface` and `GraphicsInterface` carry the descriptor set,
bindings, local size and argument declarations:

```swift
let effect = ComputeImageInterface.nucleantSwiftUI(samplesContent: true, arguments: [("tint", .float4)])
let shader = try PyShader.compile(source, target: .computeImage(effect))
```
