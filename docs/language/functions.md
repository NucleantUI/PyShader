# Functions & constants

## Global `def`s

Functions are global `def`s with annotated parameters. The return annotation
is optional — `None` when omitted, except for the entry point. Every path of
a non-`None` function must return.

```py
def palette(t: float) -> float3:
    return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)))

def checker(p: float2, size: float) -> bool:
    ix = int(floor(p.x / size))
    iy = int(floor(p.y / size))
    return (ix + iy) % 2 == 0
```

Arguments convert on the way in like assignments do (int → float, scalar →
vector). There is no recursion (SPIR-V forbids it), no keyword arguments, no
default values, and no globals inside functions — a helper that needs `time`
takes it as a parameter.

## Several results

Return a tuple, declared as `tuple[...]`; unpack at the call site or index
the result.

```py
def box(ro: float3, rd: float3) -> tuple[float, float3]:
    ...
    return t, normal

t, n = box(ro, rd)
hit = box(ro, rd)
hit[1]
```

A tuple is a struct in SPIR-V; `return a, b` converts each element to its
declared slot.

## Lambdas

A lambda bound to a module-level name is a function that is instantiated
once per distinct argument-type signature at its call sites:

```py
sq = lambda x: x * x
add3 = lambda a, b, c: a + b + c

sq(uv.x)    # float
sq(uv)      # float2
```

Immediately-invoked lambdas (`(lambda x: x + 1.0)(t)`) work too.

## Module constants

Assignments at module level are constants, inlined where used. They may be
scalars, vectors, matrices, tuples or lists; an annotation is optional.

```py
PI = 3.14159265
RED: float3 = float3(1.0, 0.0, 0.0)
HALF_RED = RED * 0.5
NO_HIT = (False, -1.0, float3(0.0))
QUAD = [float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0)]
```

## Imports and docstrings

`from pyshader import *` and `import pyshader` are accepted and ignored so an
editor can be pointed at the stub package; `pyshader.sin(x)` works. Docstrings
are allowed on the module and on functions. Nothing else can be imported and
there are no classes except the plain structs described in
[Classes](classes.md).

## In use

```pyshader
PI = 3.14159265
GOLD = float3(1.0, 0.8, 0.3)

rot = lambda p, a: float2(p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a))

def polar(p: float2) -> tuple[float, float]:
    return length(p), atan2(p.y, p.x)

def petals(p: float2, n: float, time: float) -> float:
    r, a = polar(p)
    return smoothstep(0.02, 0.0, abs(r - 0.3 - 0.15 * cos(a * n + time)))

def main(uv: float2, time: float, resolution: float2) -> float4:
    p = (uv - 0.5) * float2(resolution.x / resolution.y, 1.0)
    p = rot(p, time * 0.3)
    color = float3(0.05, 0.03, 0.1)
    color += GOLD * petals(p, 5.0, time)
    color += GOLD.bgr * petals(p, 7.0, -time * 1.3) * 0.6
    return float4(color, 1.0)
```
