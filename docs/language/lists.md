# Lists & tuples

## Lists are fixed-size arrays

A list literal, or Python's `[x] * n` repeat idiom, declares an array whose
element type comes from the first element and whose length from the value.
Indexing is dynamic, read or write, and swizzles chain off elements.

```py
colors = [float4(0.0)] * 3
w: list[float] = [0.13, 0.07, 0.03]
colors[i] = float4(w[i])
colors[i].rgb *= 0.5
colors[0], colors[1] = colors[1], colors[0]     # swap
len(w)                                          # a constant
```

Lists cannot be function parameters yet and cannot nest.

## Tuples

Tuples are how a function returns several values and how several are
assigned at once:

```py
def box(ro: float3, rd: float3) -> tuple[float, float3]:
    ...
    return t, normal

t, n = box(ro, rd)
x, y = uv                 # unpack a vector
a, b = 1, 2
a, b = b, a               # swap
MISS = (False, -1.0, float3(0.0))   # a tuple constant
```

`len()` works on any composite: a vector, a list, a tuple.

## `FloatArray`

`FloatArray` is the one host-provided array: a `.floatArray` `ShaderArgument`
handed to `main` on the [compute](../targets/compute.md) and
[graphics](../targets/graphics.md) targets. `a[i]` reads (clamped to the
ends, `0.0` when empty) and `len(a)` counts; it cannot be stored or passed on.

## In use

Three colours in a list, indexed by a value computed per pixel, with the
weights in a second list:

```pyshader
def main(uv: float2, time: float) -> float4:
    colors = [float3(0.9, 0.2, 0.3), float3(0.2, 0.8, 0.5), float3(0.3, 0.4, 1.0)]
    w: list[float] = [0.5, 0.3, 0.2]
    colors[0], colors[2] = colors[2], colors[0]
    k = int(uv.x * 3.0 + time) % 3
    strength = w[k]
    wobble = sin(uv.y * 20.0 + time * 2.0) * 0.5 + 0.5
    x, y = uv
    return float4(colors[k] * (0.4 + strength + 0.3 * wobble * y), 1.0)
```
