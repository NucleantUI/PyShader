# Builtins

GLSL 450 names, with Metal spellings accepted as aliases. Integer arguments
to float functions are promoted (`sin(1)` works). Scalars broadcast against
vectors where GLSL allows it: `min(v, 0.5)`, `clamp(v, 0.0, 1.0)`,
`pow(v, 2.0)`, `mix(a, b, 0.5)`, `step(0.5, v)`.

| Group | Functions |
|---|---|
| Trigonometry | `sin` `cos` `tan` `asin` `acos` `atan(x)` `atan(y, x)` `atan2` `sinh` `cosh` `tanh` `asinh` `acosh` `atanh` `radians` `degrees` |
| Exponential | `pow` `exp` `exp2` `log` `log2` `sqrt` `inversesqrt` / `rsqrt` |
| Common | `abs` `sign` (float and signed int) `floor` `ceil` `round` (to even) `trunc` `fract` `mod` `min` `max` (n-ary like Python, int and float) `clamp` `saturate` `mix` / `lerp` `step` `smoothstep` `fma` `isnan` `isinf` |
| Split and scale | `modf(x) -> (fraction, whole)` and `frexp(x) -> (mantissa, exponent)` as Python's `math` returns them; `ldexp(x, e)` |
| Packing | `packUnorm4x8` `packSnorm4x8` `packUnorm2x16` `packSnorm2x16` `packHalf2x16` (`floatN` → `uint`) and the matching `unpack…` (`uint` → `floatN`); Metal's `pack_float_to_unorm4x8` / `unpack_unorm4x8_to_float` spellings for the norm ones |
| Bits | `bitCount` (int result, as GLSL) / `popcount` (the argument's type, as Metal) `bitfieldReverse` / `reverse_bits` `bitfieldExtract` / `extract_bits` `bitfieldInsert` / `insert_bits` `findLSB` `findMSB` (an int index, -1 for no set bit); `floatBitsToInt` `floatBitsToUint` `intBitsToFloat` `uintBitsToFloat` — on 32-bit ints, `short` / `ushort` widen first |
| Geometric | `length` `distance` `dot` `cross` `normalize` `faceforward` `reflect` `refract` |
| Matrices | `transpose` `determinant` `inverse` `outerProduct(c, r)` (`len(r)` columns of `len(c)` rows) |
| Vector relational | `any` `all` — on a `boolN` from a vector comparison |
| Derivatives | `dfdx` / `dFdx` `dfdy` / `dFdy` `fwidth`, and the fine and coarse ones: `dFdxFine` / `dfdx_fine` `dFdyFine` `fwidthFine` `dFdxCoarse` `dFdyCoarse` `fwidthCoarse` — [fragment target](../targets/fragment.md) only: an error in compute as in GLSL, and in the graphics target's fragment stage |
| Fragment control | `discard()` — fragment target only |
| Host resources | `layer(p: float2) -> float4` — the view under a `.shader(_:)` effect ([compute](../targets/compute.md) and [graphics](../targets/graphics.md) targets); `len(a)` on an array argument (`FloatArray` … `Float4Array`), a list, a tuple or a vector |
| Textures | `a(p: float2) -> float4` and `a_size` (`int2`) for a `Texture` parameter `a` — compute and graphics targets, see [Textures](../targets/compute.md#textures) |

All map to `GLSL.std.450` or core SPIR-V ops.

## Constants

| Name | Value |
|---|---|
| `PI` | π, at the precision a `float` holds — nothing to define in the shader |

A module that binds the name itself wins, so a shader carrying its own
`PI = 3.14159265` compiles as it always did.

!!! note "Previews on this site"
    WebGPU has no `isnan` / `isinf`, no 16-bit integers and no push
    constants, so a preview that uses them shows the translation error
    instead of a picture. Derivatives and `discard` need the fragment
    target, which the previews do not use. Everything else runs.

## Not there yet

| Feature | Notes |
|---|---|
| texture reads beyond `a(uv)` | implicit LOD, an explicit `lod` / `grad`, `fetch`, `gather`; cube, 3D and array images |
| `select(a, b, c)` | use `b if c else a` |
| `roundEven` vs `round` | `round()` maps to `RoundEven` (deterministic); GLSL's `round` is implementation-defined at .5 |

## In use

```pyshader
def main(uv: float2, time: float, resolution: float2, mouse: float2) -> float4:
    p = (uv - 0.5) * float2(resolution.x / resolution.y, 1.0)
    m = (mouse / resolution - 0.5) * float2(resolution.x / resolution.y, 1.0)
    d = distance(p, m)
    n = normalize(float3(p, 0.5))
    l = normalize(float3(cos(time), sin(time), 0.8))
    diffuse = max(dot(n, l), 0.0)
    spec = pow(max(dot(reflect(-l, n), float3(0.0, 0.0, 1.0)), 0.0), 16.0)
    ring = smoothstep(0.03, 0.0, abs(fract(d * 6.0 - time) - 0.5) - 0.4)
    base = mix(float3(0.1, 0.2, 0.5), float3(0.9, 0.5, 0.2), saturate(diffuse))
    color = base + spec + ring * float3(0.3)
    color = clamp(color, 0.0, 1.0)
    return float4(color, 1.0)
```
