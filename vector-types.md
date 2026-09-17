# Vector types

PyShader types follow Metal's spelling: `<scalar><N>` with N in 2...4. Type names
are also constructors.

| Scalar   | SPIR-V              | Vectors                       | Notes |
|----------|---------------------|-------------------------------|-------|
| `float`  | `OpTypeFloat 32`    | `float2` `float3` `float4`    | Python float literals (`1.5`) |
| `half`   | `OpTypeFloat 16`    | `half2` `half3` `half4`       | adds `Float16` capability; device needs `shaderFloat16` |
| `int`    | `OpTypeInt 32 1`    | `int2` `int3` `int4`          | Python int literals (`7`, `0xFF`) |
| `uint`   | `OpTypeInt 32 0`    | `uint2` `uint3` `uint4`       | for hashing / bit tricks |
| `short`  | `OpTypeInt 16 1`    | `short2` `short3` `short4`    | adds `Int16` capability; device needs `shaderInt16` |
| `ushort` | `OpTypeInt 16 0`    | `ushort2` `ushort3` `ushort4` | |
| `bool`   | `OpTypeBool`        | `bool2` `bool3` `bool4`       | vector comparisons produce these |

## Matrices

`float2x2` … `float4x4` (and `half…`): C columns of R-component vectors,
column-major like Metal and GLSL.

```py
m = float3x3(c0, c1, c2)           # column vectors
m = float3x3(a, b, c, d, e, f, g, h, i)   # 9 scalars, column-major
m = float3x3()                     # identity
m = float3x3(2.0)                  # diagonal
m = float4x4(m3)                   # resize, identity-filled
m[1]                               # a column; m[1][2] a component
m * v      # OpMatrixTimesVector      v * m    # OpVectorTimesMatrix
m * n      # OpMatrixTimesMatrix      m * 2.0  # OpMatrixTimesScalar
m @ v      # same as *; on two vectors `@` is the dot product
m + n, m - n, m / 2.0              # column by column
transpose(m), determinant(m), inverse(m)
```

## Lists (fixed-size arrays)

```py
xs = [float4(0.0)] * 3             # Python's repeat idiom
w: list[float] = [0.13, 0.07, 0.03]
xs[i] = v                          # dynamic index, read or write
xs[i].rgb *= 0.5
xs[0], xs[1] = xs[1], xs[0]        # swap
len(xs)                            # a constant
```

Element type comes from the first element; the length from the value. Lists
cannot be parameters yet and cannot nest.

## Tuples (several return values)

```py
def box(ro: float3, rd: float3) -> tuple[float, float3]:
    ...
    return t, normal

t, n = box(ro, rd)
hit = box(ro, rd); hit[1]
```

A tuple is a struct in SPIR-V; `return a, b` converts each element to its
declared slot. Module constants may be tuples (`MISS = (False, -1.0, float3(0.0))`).

`FloatArray` is the host-provided array: a `.floatArray` `ShaderArgument`
handed to `main` on the compute target — `a[i]` and `len(a)` only, not
storable or passable. There are no structs or textures beyond `layer()` yet
(see `shader-api-status.md`).

## Declaring variables

A variable's type is fixed by its first assignment or annotation. Reassigning
with a type that does not implicitly convert is an error.

```py
a: float3              # declared, undefined until assigned
b: int4
c: float = 2           # int literal converts to float
d = float4(a, c)       # inferred float4
e = 1                  # int
e = 2.5                # error: cannot implicitly convert float to int
```

## Constructors

```py
float4(1, 0, 0, 1)     # components (ints convert)
float3(uv, 1.0)        # vector + scalar flatten in order
float4(rgb, 1.0)
float2(0.5)            # splat
float3(v4)             # truncate to the first 3 components
float(i)               # scalar conversion
int(2.7)               # truncates toward zero, like Python
bool(x)                # x != 0
uint2(int2(p))         # same-width int conversions are bit casts
float3()               # zero
```

Constructors whose arguments are all literals fold into `OpConstantComposite`.

## Swizzles

Read with `.xyzw` or `.rgba` (not mixed), 1 to 4 letters, repeats allowed on
read. Write to a swizzle of a *variable* with no repeated letters.

```py
p = uv.yx
color.rgb *= 0.5
color.a = 1.0
c[0] = 1.0             # indexing works too, negative indices wrap
c[i]                   # dynamic index -> OpVectorExtractDynamic
x, y = uv              # unpack components
```

## Promotion rules

In `a <op> b` the operands are brought to a common type:

- int + float -> float; half + float -> float; short + int -> int
- int literal next to a `uint` becomes `uint` (`h * 12345`)
- `int` + `uint` (non-literal) is an error; convert explicitly
- scalar + vector -> the scalar is splat; `float3 * float` uses `OpVectorTimesScalar`
- float2 + float3 is an error
- bool never converts implicitly to a number (`float(flag)` works)

Implicit conversions on assignment and argument passing: int -> float, narrower
-> wider, scalar -> vector. Never float -> int.

## Python operator semantics

| Python | floats | ints |
|--------|--------|------|
| `/`    | `OpFDiv` | converts to float first (true division) |
| `//`   | `floor(a / b)` | floored division (`-7 // 2 == -4`) |
| `%`    | `OpFMod` (sign of divisor) | `OpSMod` / `OpUMod` (sign of divisor) |
| `**`   | `pow` | converts to float, `pow` |
| `& | ^ << >>` | error | `OpBitwise*`, `OpShiftLeftLogical`, arithmetic/logical right shift |
| `& | ^` on bools | logical and / or / xor | |
| `a < b < c` | chained, scalars only | |
| `==` `<` ... on vectors | component-wise -> `boolN` (`any()`/`all()` to reduce) | |
| `x if c else y` | `OpSelect`, both sides evaluated | |
| `and` `or` `not` | `OpLogical*`, no short-circuit (no side effects in shaders) | |
