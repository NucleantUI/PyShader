# Shader API status

What the compiler accepts today, and what is still to do. All builtins map to
GLSL.std.450 or core SPIR-V ops; Metal spellings are accepted as aliases.
Integer arguments to float functions are promoted (`sin(1)` works).
Scalars broadcast against vectors where GLSL allows it (`min(v, 0.5)`,
`clamp(v, 0.0, 1.0)`, `pow(v, 2.0)`, `mix(a, b, 0.5)`, `step(0.5, v)`).

## Implemented

### Trigonometry
`sin` `cos` `tan` `asin` `acos` `atan(x)` `atan(y, x)` `atan2` `sinh` `cosh`
`tanh` `asinh` `acosh` `atanh` `radians` `degrees`

### Exponential
`pow` `exp` `exp2` `log` `log2` `sqrt` `inversesqrt` / `rsqrt`

### Common
`abs` `sign` (float and signed int) `floor` `ceil` `round` (to even) `trunc`
`fract` `mod` `min` `max` (n-ary like Python, int and float) `clamp`
`saturate` `mix` / `lerp` `step` `smoothstep` `fma` `isnan` `isinf`

### Geometric
`length` `distance` `dot` `cross` `normalize` `faceforward` `reflect` `refract`

### Matrices
`transpose` `determinant` `inverse`; `*` / `@` products, `m[i]`, `m[i][j]`
(see `vector-types.md`)

### Vector relational
`any` `all` (on `boolN` from vector comparisons)

### Derivatives (fragment target only)
`dfdx` / `dFdx` `dfdy` / `dFdy` `fwidth` — an error in the compute target,
as in GLSL compute.

### Fragment control (fragment target only)
`discard()` -> `OpKill`

### Host resources (compute target)
`layer(p: float2) -> float4` — the view under a `.shader(_:)` effect, sampled
with explicit LOD 0 (binding 2). `FloatArray` / `Float2Array` … `Float4Array`
arguments: `a[i]` (clamped, zero when empty), `len(a)`.

### Conversions / constructors
Every type name (`float`, `int`, `uint`, `half`, `short`, `ushort`, `bool`,
`floatN`, `intN`, ...) — see `vector-types.md`.

### Language
- global `def` functions with annotated parameters; return annotation
  optional (`None` when omitted, except `main`)
- module-level constants (`PI = 3.14`, `RED = float3(1, 0, 0)`), inlined at
  each use
- lambdas bound to a module-level name (`sq = lambda x: x * x`), instantiated
  once per distinct argument-type signature; immediately-invoked lambdas
- `if` / `elif` / `else`, `while`, `for i in range(stop | start, stop | start, stop, step)`,
  `break`, `continue`, `return`, `pass`
- tuple unpacking (`x, y = uv`, `a, b = 1, 2`), chained assignment, swaps
- tuple returns (`-> tuple[float, float3]`), list literals / `[x] * n` as
  fixed-size arrays with dynamic indexing, `len()` on any composite
- matrices `float2x2` … `float4x4` with Metal/GLSL product semantics
- `from pyshader import *` / `import pyshader` are accepted and ignored so
  editors can be pointed at a stub; `pyshader.sin(x)` works
- docstrings

### Entry point
`def main(...) -> float4`. Parameters are matched by name against the target.

Compute target (`.nucleantSwiftUI`, NucleantSwiftUI's `Shader` / `.shader(_:)`):

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
| *argument*     | `float` / `float2` / `float3` / `float4` / `FloatArray` / `Float2Array` … `Float4Array` | the `ShaderArgument` of that name, binding 3 |

Fragment target (`.nucleant`, NucleantVulkan's `NucleantShader` layout):

| parameter      | type     | source |
|----------------|----------|--------|
| `uv`           | `float2` | `location 0` input (`vTexCoord`) |
| `color`        | `float4` | `location 1` input (vertex color, if the pipeline provides one) |
| `frag_coord`   | `float4` | `BuiltIn FragCoord` |
| `front_facing` | `bool`   | `BuiltIn FrontFacing` |
| `time`         | `float`  | push constant, offset 0 |
| `resolution`   | `float2` | push constant, offset 8 |
| `mouse`        | `float2` | push constant, offset 16 |

Output is `fragColor` at `location 0`. Returning nothing from `main` forwards
`color` when it is a parameter; otherwise it is an error.

## Not yet

| Feature | Notes |
|---------|-------|
| textures / samplers beyond `layer()` | a general `sample(texture, uv)` with declared bindings |
| list parameters, nested lists, `for x in xs` | a list's length is only known from its value today |
| matrix kind conversion (`half3x3(float3x3)`) | column-wise `OpFConvert` |
| `\` line continuation | PySwiftAST rejects it; wrap in parentheses |
| classes -> structs | needs a pyclass -> `OpTypeStruct` design |
| uniform buffers | only push constants today |
| vertex / compute stages | only `Fragment` execution model |
| `modf` `frexp` `ldexp` | multiple return values |
| `roundEven` vs `round` | `round()` currently maps to `RoundEven` (deterministic); GLSL `round` is implementation-defined for .5 |
| `select(a, b, c)` | use `b if c else a` |
| bit ops: `bitcount`, `findLSB`, `reverse_bits` | `OpBitCount` etc. |
| packing: `pack_half2x16` ... | GLSL.std.450 pack/unpack |
| `while ... else`, `for ... else`, `match`, comprehensions, f-strings | not shader-shaped |
| Python stub module (`pyshader/__init__.pyi`) | for editor type checking of shader files |
| running the output on a GPU in tests | `Examples/NucleantSwiftUIExample` does it by hand; unit tests use `spirv-val` and `spirv-opt` |
| constant folding beyond literals | drivers do it; `spirv-opt --target-env=vulkan1.0 -O` if wanted offline |
