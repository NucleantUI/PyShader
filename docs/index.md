# PyShader

Shaders in Python syntax, compiled straight to SPIR-V. No GLSL in between.

```pyshader
from pyshader import *

def main(uv: float2, time: float) -> float4:
    color = float4(uv, 0.5 + 0.5 * sin(time), 1.0)
    color.rgb *= 0.6 + 0.4 * cos(time + uv.x * 6.0)
    return color
```

`main` runs once per pixel and returns its colour. It takes what it needs by
parameter name — `uv`, `frag_coord`, `time`, `resolution`, `mouse`, … — and
the compiler wires those up. `from pyshader import *` is for the editor
(completion, type errors); the compiler ignores it.

Every preview on this site is the real compiler: the page's Python goes
through PyShader (compiled to WebAssembly) to SPIR-V, then through
[naga](https://github.com/gfx-rs/wgpu/tree/trunk/naga) to WGSL, and WebGPU
draws it. Move the pointer over a preview that reads `mouse`. The
[Playground](playground.md) lets you edit and see the result as you type.

## Where it runs

PyShader is a Swift package. Its output is a SPIR-V module for one of three
pipeline shapes: a **fragment** stage, a **compute** stage writing an image,
or a **vertex + fragment** pair — the shapes NucleantVulkan and NucleantSwiftUI
use. In NucleantSwiftUI a shader is one line:

```swift
Shader(ShaderFunction(pyshader: source))
```

See [Getting started](getting-started.md) for the Swift API, the `pyshaderc`
command line and the editor stubs, [Targets](targets/index.md) for what each
pipeline shape gives `main`, and the [Examples](examples/index.md) for the
whole language in use.

## The language in one screen

```pyshader
TURN = 2.0 * PI                          # module constants are inlined; PI is a builtin

def palette(t: float) -> float3:         # global defs with annotated parameters
    return 0.5 + 0.5 * cos(TURN * (t + float3(0.0, 0.33, 0.67)))

def box(p: float2) -> tuple[float, float2]:   # several results come back as a tuple
    d = abs(p) - 0.3
    return length(max(d, 0.0)), sign(p)

sq = lambda x: x * x                     # lambdas instantiate per argument type

def main(uv: float2, time: float, mouse: float2, resolution: float2) -> float4:
    p = (uv - 0.5) * float2(resolution.x / resolution.y, 1.0)
    d, s = box(p)
    color = palette(d * 4.0 + time)
    for i in range(3):                   # ints; break / continue / early return anywhere
        color += 0.05 * sin(float(i) + sq(p.x))
    if d < 0.0:
        color *= 0.5
    elif d < 0.01:
        color = float3(1.0)
    color.rgb = clamp(color, 0.0, 1.0)   # swizzles read and write
    return float4(color, 1.0)
```

Types are Metal's (`float2`, `half3`, `int4`, `float3x3` …), builtins are
GLSL's with Metal spellings accepted, and operators keep Python semantics
(`/` is true division, `//` floors, `%` takes the divisor's sign, `**` is
`pow`, `@` is the dot product on vectors). Read on in [Language](language/types.md).
