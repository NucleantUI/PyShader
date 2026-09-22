# Compute target

`.computeImage(ComputeImageInterface)` — `.nucleantSwiftUI` — compiles
`main` as a compute stage that writes one pixel per invocation into an
`rgba8` storage image. It is what NucleantSwiftUI's `Shader` view and
`.shader(_:)` effect run, and what the previews on this site run.

| parameter      | type     | source |
|----------------|----------|--------|
| `uv`           | `float2` | `frag_coord / resolution`, y-up |
| `frag_coord`   | `float2` | pixel centre, y-up (ShaderToy's `fragCoord`) |
| `pixel`        | `int2`   | store location, y-down |
| `time`         | `float`  | `Uniforms.timeInfo.x` |
| `time_delta`   | `float`  | `Uniforms.timeInfo.y` |
| `frame`        | `int`    | `Uniforms.timeInfo.z` |
| `resolution`   | `float2` | `imageSize(uOutput)` |
| `mouse`        | `float2` | `Uniforms.mouseInfo.xy`, y flipped |
| `mouse_click`  | `float2` | `Uniforms.mouseInfo.zw`, y flipped |
| *argument*     | `float` / `float2` / `float3` / `float4` / `FloatArray` / `Float2Array` … `Float4Array` | the `ShaderArgument` of that name |

## Bindings

Descriptor set 0, local size 8 × 8:

| binding | resource |
|---|---|
| 0 | `writeonly image2D` rgba8, the output |
| 1 | `Uniforms { vec4 timeInfo; vec4 res; vec4 mouseInfo; }`, std140 |
| 2 | `sampler2D` of the view under the effect — only with `samplesContent: true`; enables `layer()` |
| 3 | `readonly buffer { float data[]; }` — only with arguments |

The argument buffer starts with an `(offset, count)` float pair per argument,
then the values, an array's elements packed one after another; `a[i]` on an
array clamps to the ends.

## Effects: `layer()`

Under a `.shader(_:)` effect the shader reads the view it is applied to with
`layer(p)`, sampled at `p` in `uv` space with explicit LOD 0:

```pyshader file="Examples/compute/effect_ripple.py"
```

The previews use a test card as the content image; the [Effects](../examples/effects.md)
page shows the whole gallery.

## Arguments

```swift
let interface = ComputeImageInterface.nucleantSwiftUI(
    samplesContent: false,
    arguments: [("gain", .float), ("tint", .float4), ("mins", .floatArray)]
)
let shader = try PyShader.compile(source, target: .computeImage(interface))
```

In NucleantSwiftUI the same declaration comes from the `ShaderArgument`s
handed to `Shader(_:arguments:)`; `main` takes them by name:

```pyshader file="Examples/compute/arguments.py" args="gain:float=1.5, tint:float4=1 0.6 0.2 1, mins:floatArray=0.2 0.5 0.9 0.4"
```

An argument name that is also a built-in input is an error.
