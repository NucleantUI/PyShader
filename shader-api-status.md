# Shader API status

What the compiler accepts today, and what is still to do. What could be added
next, and the SPIR-V each item needs, is in [expand-api.md](expand-api.md).

All builtins map to GLSL.std.450 or core SPIR-V ops; Metal spellings are
accepted as aliases. Integer arguments to float functions are promoted
(`sin(1)` works). Scalars broadcast against vectors where GLSL allows it:
`min(v, 0.5)`, `clamp(v, 0.0, 1.0)`, `pow(v, 2.0)`, `mix(a, b, 0.5)`,
`step(0.5, v)`.

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

### Split and scale
`modf(x) -> (fraction, whole)`, `frexp(x) -> (mantissa, exponent)` (Python's
`math` order), `ldexp(x, e)`. `modf` and `frexp` are built from core ops,
not GLSL.std.450's `ModfStruct` / `FrexpStruct`, whose result type naga (the
web build) cannot resolve; `frexp` reads the float's bits, so it is exact.

### Packing
`packUnorm4x8` `packSnorm4x8` `packUnorm2x16` `packSnorm2x16` `packHalf2x16`
and the `unpack…` of each; Metal's `pack_float_to_unorm4x8` /
`unpack_unorm4x8_to_float` spellings for the norm ones.

### Bits
`bitCount` (int) / `popcount` (the argument's type), `bitfieldReverse` /
`reverse_bits`, `bitfieldExtract` / `extract_bits`, `bitfieldInsert` /
`insert_bits`, `findLSB`, `findMSB` (int, -1 for no set bit),
`floatBitsToInt` `floatBitsToUint` `intBitsToFloat` `uintBitsToFloat`. On
32-bit integers, as Vulkan requires; `short` / `ushort` widen first.

### Geometric
`length` `distance` `dot` `cross` `normalize` `faceforward` `reflect` `refract`

### Matrices
`transpose` `determinant` `inverse` `outerProduct(c, r)`; `*` / `@` products, `m[i]`, `m[i][j]`
(see `vector-types.md`)

### Vector relational
`any` `all` (on `boolN` from vector comparisons)

### Derivatives (fragment target only)
`dfdx` / `dFdx`, `dfdy` / `dFdy`, `fwidth`, and the fine and coarse ones
(`dFdxFine` / `dfdx_fine`, `dFdyCoarse`, `fwidthFine`, …, capability
`DerivativeControl`). They are an error in the compute
target, as in GLSL compute, and also in the graphics target's fragment stage
(see Not yet).

### Fragment control (fragment target only)
`discard()` → `OpKill`

### Host resources (compute and graphics targets)
- `layer(p: float2) -> float4`: the view under a `.shader(_:)` effect, sampled
  with explicit LOD 0 (binding 2).
- `FloatArray` / `Float2Array` … `Float4Array` arguments: `a[i]` (clamped,
  zero when empty) and `len(a)`.

### Textures (compute and graphics targets)
A `main` parameter typed `Texture`, which the target declares as a
`ShaderTexture` (binding 4 and up in NucleantUI's layout).
- `a(p)` samples it at explicit LOD 0, flipped for a top-down image.
- `a_size` is its size in pixels (`int2`).

### Conversions / constructors
Every type name (`float`, `int`, `uint`, `half`, `short`, `ushort`, `bool`,
`floatN`, `intN`, ...) — see `vector-types.md`.

### Language
- Global `def` functions with annotated parameters. The return annotation is
  optional: `None` when omitted, except for `main`.
- Module-level constants (`PI = 3.14`, `RED = float3(1, 0, 0)`), inlined at
  each use. `PI` is built in.
- Module variables: a module-level name a function declares `global` is a
  per-invocation `Private` variable, set from its initializer before the entry
  point runs.
- Classes: plain structs with annotated fields only, constructed positionally
  or by keyword and read with `v.field`. A vertex stage returns one.
- Lambdas bound to a module-level name (`sq = lambda x: x * x`), instantiated
  once per distinct argument-type signature, and immediately-invoked lambdas.
- Control flow: `if` / `elif` / `else`, `while`,
  `for i in range(stop | start, stop | start, stop, step)`, `break`,
  `continue`, `return`, `pass`, and `match` on an int or uint with int
  literal cases, `|` and `_` (→ `OpSwitch`).
- Driver hints: `@inline` / `@noinline` on a function, `for i in
  unroll(range(...))` / `dont_unroll(range(...))`. The decompiler drops them.
- Tuple unpacking (`x, y = uv`, `a, b = 1, 2`), chained assignment and swaps.
- Tuple returns (`-> tuple[float, float3]`).
- List literals and `[x] * n` as fixed-size arrays: dynamic indexing, nesting
  (`g[i][j]`), and `len()` on any composite.
- Matrices `float2x2` … `float4x4`, with Metal/GLSL product semantics.
- `from pyshader import *` and `import pyshader` are accepted and ignored, so
  editors can be pointed at the stub; `pyshader.sin(x)` works.
- Docstrings.

### Entry point
`def main(...) -> float4`, or `vertex` and `fragment` in the graphics target.
Parameters are matched by name against the target.

Compute target (`.nucleantUI`, NucleantUI's `Shader` / `.shader(_:)`):

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
| *texture*      | `Texture` | the `ShaderTexture` of that name, binding 4 and up |

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

Graphics target (`.nucleantUIGraphics`, NucleantUI's `VertexShader`):
- `vertex` takes `vertex_index`, `instance_index`, the uniforms (`time` …
  `mouse_click`), arguments and textures. It returns a class whose first field
  is the `float4` position.
- `fragment` takes the uniforms, arguments, textures, `uv`, `frag_coord`,
  `pixel`, `front_facing`, and the varyings by name.
- See [docs/targets/graphics.md](docs/targets/graphics.md).

## Not yet

| Feature | Notes |
|---------|-------|
| texture reads beyond `a(uv)` | Implicit LOD in a fragment stage, an explicit `lod` / `grad`, `fetch`, `gather`, `a_levels`, and cube, 3D and array images. See expand-api.md. |
| textures in the fragment target | Only the compute and graphics targets declare them. |
| derivatives and `discard()` in the graphics target's fragment stage | Refused today, with the compute target's message. |
| list parameters, `for x in xs` | A list's length is only known from its value. A `list[...]` parameter currently crashes the compiler instead of reporting an error. Loop over `range(len(xs))` instead. |
| matrix kind conversion (`half3x3(float3x3)`) | Column-wise `OpFConvert`. |
| `\` line continuation | PySwiftAST rejects it; wrap the expression in parentheses. |
| user-declared uniform blocks | A shader reads the target's own `Uniforms` block or push constants, and the argument buffer (`ShaderArgument`s). |
| a general compute target | `.computeImage` runs one invocation per pixel. Writable buffers, shared memory, barriers and atomics are in expand-api.md. |
| other stages | Geometry, tessellation, mesh and ray tracing. expand-api.md says which are realistic. |
| `roundEven` vs `round` | `round()` currently maps to `RoundEven` (deterministic); GLSL's `round` is implementation-defined at .5. |
| `select(a, b, c)` | Use `b if c else a`. |
| `match` beyond int literals | Capture, class, sequence and mapping patterns, and guards (which PySwiftAST cannot parse yet). |
| decorators besides `@inline` / `@noinline`, default parameter values, keyword arguments in calls | Keyword arguments work only when constructing a class. |
| `while ... else`, `for ... else`, comprehensions, f-strings | Not shader-shaped. |
| `Texture` in the Python stub | `src/pyshader` has `FloatArray` … but no `Texture`, so an editor flags `a: Texture`. `scripts/generate_stub.py` doesn't know it yet. |
| running the output on a GPU in tests | `Examples/NucleantUIExample` does it by hand; unit tests use `spirv-val` and `spirv-opt`. |
| constant folding beyond literals | Drivers do it; use `spirv-opt --target-env=vulkan1.0 -O` to do it offline. |
