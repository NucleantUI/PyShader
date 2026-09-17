# ShaderToy ports

[Examples/shadertoy/](https://github.com/NucleantUI/PyShader/tree/main/Examples/shadertoy)
holds ShaderToy shaders as written in `opengl/` and the same shaders in
PyShader in `pyshader/`, structured function for function so they can be
read side by side. `App/` runs each pair next to each other in
NucleantSwiftUI: the GLSL through `ShaderFunction(shaderToy:)`, the Python
through `ShaderFunction(pyshader:)`. A port is right when the two halves match.

## What porting needed

| GLSL | PyShader |
|---|---|
| `mat2` / `mat3`, `m * v`, `v * m`, `m * m`, `m * s` | `float2x2` … `float4x4`; `*` and `@` are matrix products, `+ - /` column-wise; `transpose`, `determinant`, `inverse`; `m[i]`, `m[i][j]` |
| `out` parameters | tuple returns: `-> tuple[bool, float, float3]`, `return hit, t, n`, `hit, t, n = f(...)` |
| `vec4[3]` locals, dynamic index, a `swap` macro | list literals: `[float4(0.0)] * 3`, `xs[i]`, `xs[i].rgb *= …`, `xs[0], xs[1] = xs[1], xs[0]`, `len(xs)` |
| `#define` constants, `const` | module-level constants |
| helpers reading `iTime` / `iResolution` | take `time` / `resolution` as a parameter — the inputs are `main`'s, not globals |
| file-scope variables set in `mainImage`, read in helpers | [module variables](../language/functions.md#module-variables): assign at module level, `global name` where written |
| `for (float x = 3000.0; x >= 0.0; x -= 6.67)` | `while` (`range` is ints) |
| `#if` / `#ifdef` | the chosen branch is what gets ported |
| `iMouse.z > 0.0`, `iMouse.xy` | `mouse_click.x > 0.0`, `mouse` (y-up, as the wrapper flips it) |
| `fwidth` / `dFdx` | fragment-only, as in GLSL; cube-lines takes an 8-tap `fcos` path without derivatives instead |
| alpha | ShaderToy ignores the alpha a shader writes; NucleantSwiftUI composites with it, so ports end with `float4(rgb, 1.0)` |

Noticed on the way: `\` line continuation is not accepted — wrap long
expressions in parentheses; lists cannot be parameters or nest; matrices
convert only within one scalar kind; `for x in xs` is `for i in range(len(xs))`.

## Cyber Fuji 2020

[shadertoy.com/view/Wt33Wf](https://www.shadertoy.com/view/Wt33Wf) — Jan Mróz (jaszunio15), CC BY 3.0.

```pyshader-preview file="Examples/shadertoy/pyshader/cyber-fuji-2020.py" height="360"
```

??? example "cyber-fuji-2020.py"
    ```py
    --8<-- "Examples/shadertoy/pyshader/cyber-fuji-2020.py"
    ```

??? example "cyber-fuji-2020.glsl"
    ```glsl
    --8<-- "Examples/shadertoy/opengl/cyber-fuji-2020.glsl"
    ```

## Star and galaxy

[shadertoy.com/view/f3c3zX](https://www.shadertoy.com/view/f3c3zX). `#define`s
become module constants, `mat2` becomes `float2x2`, the float-stepped
`for` loops become `while` loops.

```pyshader-preview file="Examples/shadertoy/pyshader/star-and-galaxy.py" height="360"
```

??? example "star-and-galaxy.py"
    ```py
    --8<-- "Examples/shadertoy/pyshader/star-and-galaxy.py"
    ```

??? example "star-and-galaxy.glsl"
    ```glsl
    --8<-- "Examples/shadertoy/opengl/star-and-galaxy.glsl"
    ```

## Random BSP tiling

[shadertoy.com/view/cdsXDr](https://www.shadertoy.com/view/cdsXDr) — Tom'2017.
`mat3` becomes `float3x3`; `iTime` is passed down to the helpers that read it.

```pyshader-preview file="Examples/shadertoy/pyshader/bsp-titling.py" height="360"
```

??? example "bsp-titling.py"
    ```py
    --8<-- "Examples/shadertoy/pyshader/bsp-titling.py"
    ```

??? example "bsp-titling.glsl"
    ```glsl
    --8<-- "Examples/shadertoy/opengl/bsp-titling.glsl"
    ```

## Cube lines

[shadertoy.com/view/NslGRN](https://www.shadertoy.com/view/NslGRN) — Danil, CC BY-NC-SA 3.0.
The largest port: `out` parameters become tuple returns, `vec4[3]` locals
become lists, and the mouse rotates the cube.

```pyshader-preview file="Examples/shadertoy/pyshader/cube-lines.py" height="360"
```

??? example "cube-lines.py"
    ```py
    --8<-- "Examples/shadertoy/pyshader/cube-lines.py"
    ```

??? example "cube-lines.glsl"
    ```glsl
    --8<-- "Examples/shadertoy/opengl/cube-lines.glsl"
    ```
