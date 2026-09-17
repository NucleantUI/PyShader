# Classes

A `class` with annotated fields and nothing else is a plain struct.
Construct it positionally or by keyword, read fields with `v.field`.

```py
class Ray:
    origin: float3
    direction: float3

def march(r: Ray) -> float:
    ...

r = Ray(float3(0.0), normalize(float3(p, 1.0)))
r = Ray(origin=float3(0.0), direction=rd)
r.direction.z
```

No methods, no inheritance, no defaults. Fields can be any shader type,
including other structs.

## Varyings

Classes are how the [graphics target](../targets/graphics.md) passes data
from the vertex stage to the fragment stage: `vertex` returns a class whose
first field is the `float4` position; every other field is a varying that
`fragment` takes by name.

```py
class Glow:
    position: float4
    local: float2
    seed: float

def vertex(vertex_index: int, instance_index: int, touches: FloatArray) -> Glow:
    ...
    return Glow(float4(centre + corner * 0.25, 0.0, 1.0), local=corner * 0.5 + 0.5, seed=touches[t + 2])

def fragment(local: float2, seed: float, time: float) -> float4:
    ...
```

## In use

```pyshader
class Hit:
    distance: float
    color: float3


def circle(p: float2, centre: float2, radius: float, color: float3) -> Hit:
    return Hit(length(p - centre) - radius, color)


def closer(a: Hit, b: Hit) -> Hit:
    if a.distance < b.distance:
        return a
    return b


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = (uv - 0.5) * float2(resolution.x / resolution.y, 1.0)
    a = circle(p, float2(sin(time) * 0.3, 0.0), 0.2, float3(1.0, 0.3, 0.2))
    b = circle(p, float2(0.0, cos(time * 1.3) * 0.3), 0.15, float3(0.2, 0.6, 1.0))
    near = closer(a, b)
    glow = exp(-max(near.distance, 0.0) * 12.0)
    return float4(near.color * glow, 1.0)
```
