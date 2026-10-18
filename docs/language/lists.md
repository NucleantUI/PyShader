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

Lists nest. A list of lists indexes, assigns and counts at each level:

```py
g = [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]
g[i][1] = 7.0
g[2] = [8.0, 9.0]
len(g), len(g[0])                               # 3, 2
```

There is no `for x in xs`: loop over `range(len(xs))`. A list a module
constant holds indexes like any other, by a value only known at run time
too (`QUAD[vertex_index % 6]`).

## Lists as parameters

A parameter annotated `list[T]` takes a list of any length. The function is
compiled once for each length it is called with, so `len(xs)` is a constant
inside it, as in the caller. The distance to a polygon, after Inigo Quilez's
([2D distance functions](https://iquilezles.org/articles/distfunctions2d/)):

```py
def sd_polygon(v: list[float2], p: float2) -> float:
    d = dot(p - v[0], p - v[0])
    s = 1.0
    j = len(v) - 1
    for i in range(len(v)):
        e = v[j] - v[i]
        w = p - v[i]
        b = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0)
        d = min(d, dot(b, b))
        c = bool3(p.y >= v[i].y, p.y < v[j].y, e.x * w.y > e.y * w.x)
        if all(c) or not any(c):
            s = -s
        j = i
    return s * sqrt(d)

sd_polygon([float2(0.1), float2(0.9, 0.2), float2(0.5, 0.9)], uv)   # 3 corners
sd_polygon(PENTAGON, uv)                                             # 5
```

The list is passed by value: the function works on its own copy, and
assigning one of its elements changes that copy, not the caller's list.
Elements convert on the way in as other arguments do (`[1, 2, 3]` to a
`list[float]`). A function cannot return a `list[T]` of no fixed length.

The same parameter takes an array argument (`Float2Array` for a
`list[float2]`); see below.

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

## `FloatArray`, `Float2Array`, `Float3Array`, `Float4Array`

These are the host-provided arrays: a `.floatArray` (or `.float2Array` …
`.float4Array`) `ShaderArgument` handed to `main` on the
[compute](../targets/compute.md) and [graphics](../targets/graphics.md)
targets. `a[i]` reads one element — a `float`, or a `float2`/`float3`/`float4`
— clamped to the ends and zero when empty, and `len(a)` counts; an array
cannot be stored in a variable.

An array argument can be handed to a function whose parameter is a
`list[T]` of its elements, or the array type itself (`FloatArray`, …). The
function is compiled once for each array it is given, and reads that
array's elements from the buffer the host filled; nothing is copied. Given a
list instead, the same function works on the list:

```py
def centroid(pts: list[float2]) -> float2:
    c = float2(0.0)
    for i in range(len(pts)):
        c += pts[i]
    return c / float(max(len(pts), 1))

def main(uv: float2, points: Float2Array) -> float4:
    c = centroid(points)                         # the argument
    d = centroid([float2(0.0), float2(1.0)])     # a list
    ...
```

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
