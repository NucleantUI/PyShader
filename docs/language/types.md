# Types

PyShader types follow Metal's spelling: `<scalar><N>` with N in 2…4. Type
names are also constructors.

| Scalar   | SPIR-V              | Vectors                       | Notes |
|----------|---------------------|-------------------------------|-------|
| `float`  | `OpTypeFloat 32`    | `float2` `float3` `float4`    | Python float literals (`1.5`) |
| `half`   | `OpTypeFloat 16`    | `half2` `half3` `half4`       | adds the `Float16` capability; the device needs `shaderFloat16` |
| `int`    | `OpTypeInt 32 1`    | `int2` `int3` `int4`          | Python int literals (`7`, `0xFF`) |
| `uint`   | `OpTypeInt 32 0`    | `uint2` `uint3` `uint4`       | for hashing and bit tricks |
| `short`  | `OpTypeInt 16 1`    | `short2` `short3` `short4`    | adds the `Int16` capability; the device needs `shaderInt16` |
| `ushort` | `OpTypeInt 16 0`    | `ushort2` `ushort3` `ushort4` | |
| `bool`   | `OpTypeBool`        | `bool2` `bool3` `bool4`       | vector comparisons produce these |

## Constructors

```py
float4(1, 0, 0, 1)     # components; ints convert
float3(uv, 1.0)        # vector + scalar flatten in order
float4(rgb, 1.0)
float2(0.5)            # splat
float3(v4)             # truncate to the first 3 components
float(i)               # scalar conversion
int(2.7)               # truncates toward zero, like Python
bool(x)                # x != 0
uint2(int2(p))         # same-width int conversions are bit casts
half3(b)               # 16-bit
float3()               # zero
```

Constructors whose arguments are all literals fold into `OpConstantComposite`.

## Declaring variables

A variable's type is fixed by its first assignment or by an annotation.
Reassigning with a type that does not implicitly convert is an error.

```py
a: float3              # declared, undefined until assigned
b: int4
c: float = 2           # 2 becomes 2.0
d = float4(a, c)       # inferred float4
e = 1                  # int
e = 2.5                # error: cannot implicitly convert float to int
```

Implicit conversions on assignment and argument passing: int → float,
narrower → wider, scalar → vector. Never float → int: write `int(x)`.

## Swizzles

Read with `.xyzw` or `.rgba` (not mixed), 1 to 4 letters, repeats allowed on
read. Write to a swizzle of a *variable* with no repeated letters.

```py
p = uv.yx
color.rgb *= 0.5
color.a = 1.0
c[0] = 1.0             # indexing works too; negative indices wrap
c[i]                   # dynamic index
x, y = uv              # unpack components
```

## Matrices

`float2x2` … `float4x4` (and `half…`): C columns of R-component vectors,
column-major like Metal and GLSL.

```py
m = float3x3(c0, c1, c2)                  # column vectors
m = float3x3(a, b, c, d, e, f, g, h, i)   # 9 scalars, column-major
m = float3x3()                            # identity
m = float3x3(2.0)                         # diagonal
m = float4x4(m3)                          # resize, identity-filled
m[1]                                      # a column; m[1][2] a component
m * v      # matrix * vector              v * m    # vector * matrix
m * n      # matrix * matrix              m * 2.0  # matrix * scalar
m @ v      # same as *; on two vectors, @ is the dot product
m + n, m - n, m / 2.0                     # column by column
transpose(m), determinant(m), inverse(m)
```

Matrices convert only between the same scalar kind; `half3x3(float3x3)` is
not supported yet.

## Promotion rules

In `a <op> b` the operands are brought to a common type:

- int + float → float; half + float → float; short + int → int
- an int literal next to a `uint` becomes `uint` (`h * 12345`)
- `int` + `uint` (non-literal) is an error; convert explicitly
- scalar + vector → the scalar is splat; `float3 * float` uses `OpVectorTimesScalar`
- `float2 + float3` is an error
- bool never converts implicitly to a number (`float(flag)` works)

## In use

```pyshader
def main(uv: float2, time: float) -> float4:
    p = uv * 2.0 - 1.0                       # float2
    cell = int2(floor(uv * 8.0))             # explicit float -> int
    checker = (cell.x + cell.y) % 2 == 0     # bool
    h: half = half(0.25 + 0.25 * sin(time))  # 16-bit
    tint = float3(h) if checker else float3(0.1, 0.2, 0.4)
    ring = smoothstep(0.02, 0.0, abs(length(p) - 0.6))
    color = mix(tint, float3(1.0, 0.8, 0.2), ring)
    return float4(color, 1.0)
```
