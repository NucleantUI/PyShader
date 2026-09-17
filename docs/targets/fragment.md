# Fragment target

`.fragment(FragmentInterface)` — the default, `.nucleant` — compiles `main`
as a fragment stage for NucleantVulkan's `NucleantShader` pipeline: a
fullscreen quad with `vTexCoord` at location 0, `fragColor` at location 0
and a `ShaderPushConstants { time, _pad, resolution, mouse }` block.

| parameter      | type     | source |
|----------------|----------|--------|
| `uv`           | `float2` | location 0 input (`vTexCoord`) |
| `color`        | `float4` | location 1 input (vertex colour, if the pipeline provides one) |
| `frag_coord`   | `float4` | `BuiltIn FragCoord` |
| `front_facing` | `bool`   | `BuiltIn FrontFacing` |
| `time`         | `float`  | push constant, offset 0 |
| `resolution`   | `float2` | push constant, offset 8 |
| `mouse`        | `float2` | push constant, offset 16 |

Output is `fragColor` at location 0.

## Forwarding the colour

`return` without a value forwards the `color` input when `main` takes it;
otherwise a bare `return` is an error.

```py
def main(color: float4, uv: float2):
    if uv.x > 0.5:
        return float4(color.rgb * 0.5, color.a)
    return
```

## Fragment-only builtins

`dfdx` / `dfdy` / `fwidth` and `discard()` exist only here, as in GLSL: a
compute stage has no derivatives.

## Your own layout

```swift
let layout = FragmentInterface(
    inputs: [
        .init(name: "uv", type: .float(2), binding: .location(0)),
        .init(name: "frag_coord", type: .float(4), binding: .builtIn(.fragCoord)),
    ],
    pushConstants: [
        .init(name: "time", type: .float, offset: 0),
        .init(name: "resolution", type: .float(2), offset: 8),
    ],
    output: .init(name: "fragColor", type: .float(4), location: 0)
)
let shader = try PyShader.compile(source, target: .fragment(layout))
```

!!! note
    The previews on this site use the compute target: WebGPU has no push
    constants. A shader written for the fragment target previews unchanged
    as long as it takes `frag_coord` as `float2` and does not use `color`,
    `front_facing`, derivatives or `discard()`.
