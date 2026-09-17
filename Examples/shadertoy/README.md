# ShaderToy ports

`opengl/` holds four ShaderToy shaders as written; `pyshader/` holds the same
four in PyShader, structured function-for-function so they can be read side by
side. `App/` runs each pair next to each other in NucleantSwiftUI:

```sh
cd App && swift run                                   # gallery
PYSHADER_EXAMPLE_START=cube-lines swift run           # one comparison directly
```

The GLSL runs through `ShaderFunction(shaderToy:)`, the Python through
`ShaderFunction(pyshader:)`; a port is right when the two halves match.

## What the ports needed from the compiler

Porting these found three real gaps, all now implemented:

| GLSL | PyShader | Used by |
|---|---|---|
| `mat2` / `mat3`, `m * v`, `v * m`, `m * m`, `m * s` | `float2x2` … `float4x4`; `*` and `@` are matrix products, `+ - /` column-wise; `transpose`, `determinant`, `inverse`; `m[i]`, `m[i][j]` | star-and-galaxy, bsp-titling, cube-lines |
| `out` parameters | tuple returns: `-> tuple[bool, float, float3]`, `return hit, t, n`, `hit, t, n = f(...)`, `f(...)[1]` | cube-lines (`box`, `iBilinearPatch`, `background`, `insides`, `calcColor`) |
| `vec4[3]` locals, dynamic index, `swap` macro | list literals: `[float4(0.0)] * 3`, `xs: list[float] = [...]`, `xs[i]`, `xs[i].rgb *= …`, `xs[0], xs[1] = xs[1], xs[0]`, `len(xs)` | cube-lines (`insides`, `colo`) |

Things that were expressible already but read differently:

- **Alpha.** ShaderToy ignores the alpha a shader writes; NucleantSwiftUI
  composites with it. star-and-galaxy never touches `.a` and so came out fully
  transparent — in both languages. Ports end with `float4(rgb, 1.0)`; the app
  forces `fragColor.a = 1.0` after `mainImage` on the GLSL side.
- `#define` constants and `const` -> module-level constants (inlined at use).
- Helpers reading `iTime` / `iResolution` -> take `time` / `resolution` as a
  parameter; there are no globals inside functions.
- `for (float x = 3000.0; x >= 0.0; x -= 6.67)` -> `while` (`range` is ints).
- `#if` / `#ifdef` -> the chosen branch is what gets ported (noted in each docstring).
- `iMouse.z > 0.0` -> `mouse_click.x > 0.0`; `iMouse.xy` -> `mouse` (y-up, as
  the wrapper flips it).
- `fwidth` / `dFdx` are fragment-only in Vulkan as in GLSL, so cube-lines takes
  its own no-derivative 8-tap `fcos` path (the GLSL side gets
  `#define fwidth(x) (vec3(0.0))` from the app for the same reason).

Still missing / noticed on the way:

- PySwiftAST does not accept `\` line continuation; wrap long expressions in
  parentheses instead.
- Arrays cannot be function parameters yet (a list's length is only known from
  its value), and lists of lists are not supported.
- Matrices convert only between the same scalar kind; `half3x3(float3x3)` is
  an error.
- `for x in some_list` is not supported; index with `range(len(xs))`.
