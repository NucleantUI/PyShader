# Compute target

`.computeImage(ComputeImageInterface)` — `.nucleantUI` — compiles
`main` as a compute stage that writes one pixel per invocation into an
`rgba8` storage image. It is what NucleantUI's `Shader` view and
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
| *texture*      | `Texture` | the `ShaderTexture` of that name — see [Textures](#textures) |
| *any name*     | a module class | the [class input](#a-class-as-input), read whole |

## Bindings

Descriptor set 0, local size 8 × 8:

| binding | resource |
|---|---|
| 0 | `writeonly image2D` rgba8, the output |
| 1 | `Uniforms { vec4 timeInfo; vec4 res; vec4 mouseInfo; }`, std140 |
| 2 | `sampler2D` of the view under the effect — only with `samplesContent: true`; enables `layer()` |
| 3 | `readonly buffer { float data[]; }` — only with arguments; or the [class input](#a-class-as-input), at `inputBinding` |
| 4 and up | `sampler2D` per named texture, at the binding its `ShaderTexture` gives |

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
let interface = ComputeImageInterface.nucleantUI(
    samplesContent: false,
    arguments: [("gain", .float), ("tint", .float4), ("mins", .floatArray)]
)
let shader = try PyShader.compile(source, target: .computeImage(interface))
```

In NucleantUI the same declaration comes from the `ShaderArgument`s
handed to `Shader(_:arguments:)`; `main` takes them by name:

```pyshader file="Examples/compute/arguments.py" args="gain:float=1.5, tint:float4=1 0.6 0.2 1, mins:floatArray=0.2 0.5 0.9 0.4"
```

An argument name that is also a built-in input is an error.

## A class as input

A `main` parameter typed as one of the module's classes is the shader's
input, read whole from one storage buffer at `inputBinding` (3 by default):

```py
class Look:
    color_a: float4
    color_b: float4
    intensity: float

def main(uv: float2, look: Look) -> float4:
    return float4(mix(look.color_a.xyz, look.color_b.xyz, uv.x) * look.intensity, 1.0)
```

The host writes the fields in order, each at its std430 offset: a `float`
or `int` on 4 bytes, a `float2` on 8, a `float3` on 16 (12 long, so a scalar
after it fills its fourth slot), a `float4` on 16; a nested class aligns to
its widest field, a fixed-size list's elements are each rounded up to their
alignment, a matrix is a list of its columns. `Look` above is `color_a` at
0, `color_b` at 16, `intensity` at 32. A `bool` or 16-bit field cannot be
read from a buffer and is refused.

A shader takes one input class. It may sit beside arguments only at another
binding — set `inputBinding` — since both default to 3. In NucleantUI it is
what a `ShaderInput` packs: each value's `pack(into:)` puts itself at its
std430 offset, so a model packing the same fields in the same order matches.

## Textures

Besides the content image, a shader can sample images the host binds by name.
A texture is a `main` parameter typed `Texture`, and the body uses it as a
callable:

```py
def main(uv: float2, blend: float, a: Texture, b: Texture) -> float4:
    s = float2(a_size)                     # pixel size, int2
    return mix(a(uv), b(uv + float2(1.0 / s.x, 0.0)), blend)
```

`a(p)` samples at `p` in `uv` space with explicit LOD 0, as `layer(p)` does:
a compute stage has no derivatives to choose a level from. `a_size` is the
image's size in pixels. A texture is a handle, not a value: it cannot be
stored, returned or passed to a helper, and reading `a` without calling it is
an error that says how to sample it.

The interface declares each texture with its binding and orientation:

```swift
let interface = ComputeImageInterface.nucleantUI(
    samplesContent: false,
    arguments: [("blend", .float)],
    textures: [ShaderTexture(name: "a", binding: 4), ShaderTexture(name: "b", binding: 5)]
)
```

`isTopDown` (default `true`) says the image is stored top-down, as a
`RenderTexture` is, so `a(p)` reads it at `(p.x, 1 - p.y)` and sees it
upright. A texture name that is also an input or an argument is an error.

In NucleantUI the declaration comes from the `RenderTexture`s handed to the
view or effect:

```swift
Shader(mix, arguments: [.float("blend", t)], textures: [.init("a", layerA), .init("b", layerB)])
content.shader(effect, textures: [.init("noise", noise)])
```

The graphics target takes textures the same way, in either stage. The
previews on this site have no textures to bind.
