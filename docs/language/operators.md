# Operators

Operators keep Python's semantics, then lower to the SPIR-V op for the
operand types.

| Python | floats | ints |
|--------|--------|------|
| `/`    | `OpFDiv` | converts to float first (true division) |
| `//`   | `floor(a / b)` | floored division (`-7 // 2 == -4`) |
| `%`    | `OpFMod` (sign of the divisor) | `OpSMod` / `OpUMod` (sign of the divisor) |
| `**`   | `pow` | converts to float, then `pow` |
| `& \| ^ << >>` | error | `OpBitwise*`, `OpShiftLeftLogical`, arithmetic / logical right shift |
| `& \| ^` on bools | logical and / or / xor | |
| `a < b < c` | chained, scalars only | |
| `==` `<` … on vectors | component-wise → `boolN`; `any()` / `all()` reduce | |
| `x if c else y` | `OpSelect`; both sides are evaluated | |
| `and` `or` `not` | `OpLogical*`; no short-circuit (there are no side effects in a shader) | |

```py
7 / 2        # 3.5, always true division
-7 // 2      # -4, floored
-7 % 3       # 2, sign of the divisor
2 ** 3       # 8.0
v * 2.0      # scalars broadcast against vectors
m * v        # matrix * vector; v * m; m * m; m @ v is the same
a @ b        # on two vectors: dot product
uv > 0.5     # component-wise -> bool2; any() / all() to reduce
x if c else y
a < b < c    # chained
h ^ (h >> 13)  # bit ops on ints
```

`int + float → float`, `half + float → float`, an int literal next to a
`uint` becomes `uint`. Mixed vector sizes are an error.

Augmented assignment (`+=`, `*=`, `//=`, …) works on variables, swizzles and
indexed elements alike: `color.rgb *= 0.5`, `xs[i] += 1.0`.

## In use

Integer hashing with `uint`, Python division and a component-wise compare:

```pyshader
def hash21(p: float2) -> float:
    q = uint2(int2(p * 1000.0))
    h = q.x * 1103515245 + q.y * 12345
    h = h ^ (h >> 13)
    h = h * 2654435761
    return float(h & 0xFFFF) / 65535.0


def main(uv: float2, time: float) -> float4:
    cells = floor(uv * 12.0)
    n = hash21(cells + floor(time))
    inside = all(fract(uv * 12.0) > 0.1)      # bool2 -> bool
    m = int(cells.x + cells.y) % 3            # Python modulo
    base = float3(n, n * 0.5, 1.0 - n) if m == 0 else float3(0.2, n, 0.6)
    return float4(base * (1.0 if inside else 0.2), 1.0)
```
