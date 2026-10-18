# Random, noise & cellular

Randomness a shader can repeat: the same coordinates always give the same
value. Hashes scatter, noise flows, and cellular noise breaks the plane into
cells.

```py
from pyshader.stdlib.fragment.random import random, hash22
from pyshader.stdlib.fragment.noise import simplex_noise, fbm
from pyshader.stdlib.fragment.cellular import voronoi
```

## Nine kinds

One per cell. Top row: `random` per pixel, `random` per grid cell, and
`hash32` as a color per cell. Middle row: `value_noise`, `gradient_noise`
and `simplex_noise3`, animated through its third axis. Bottom row: `fbm`,
`turbulence` and `ridge`, each five octaves.

```pyshader height="380"
from pyshader import *
from pyshader.stdlib.fragment.random import random, hash32
from pyshader.stdlib.fragment.noise import value_noise, gradient_noise, simplex_noise3, fbm, turbulence, ridge
from pyshader.stdlib.fragment.pattern import tile, tile_index


def panel(i: float, st: float2, time: float) -> float3:
    p = st * 6.0 + float2(time * 0.3, 0.0)
    if i < 0.5:
        return float3(random(floor(st * 120.0) + floor(time * 8.0)))
    if i < 1.5:
        return float3(random(floor(p)))
    if i < 2.5:
        return hash32(floor(p))
    if i < 3.5:
        return float3(value_noise(p))
    if i < 4.5:
        return float3(0.5 + 0.5 * gradient_noise(p))
    if i < 5.5:
        return float3(0.5 + 0.5 * simplex_noise3(float3(st * 4.0, time * 0.3)))
    if i < 6.5:
        return float3(fbm(p * 0.5, 5))
    if i < 7.5:
        return float3(turbulence(p * 0.3, 5))
    return float3(ridge(p * 0.3, 5))


def main(uv: float2, time: float) -> float4:
    st = tile(uv, 3.0)
    cell = tile_index(uv, 3.0)
    i = cell.x + (2.0 - cell.y) * 3.0
    color = panel(i, st, time)
    edge = step(0.01, st.x) * step(0.01, st.y)
    return float4(color * edge, 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.random"
```

## Noise at work

Layered noise makes most natural things. A domain warp feeds `fbm` its own
output to make marble, and `ridge` noise in the bottom half makes a mountain
skyline, shaded by height.

```pyshader height="320"
from pyshader import *
from pyshader.stdlib.fragment.noise import fbm, ridge
from pyshader.stdlib.fragment.color import palette


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = uv * float2(resolution.x / resolution.y, 1.0) * 3.0
    q = float2(fbm(p + time * 0.05, 4), fbm(p + float2(5.2, 1.3), 4))
    marble = fbm(p + 3.0 * q, 5)
    sky = palette(marble, float3(0.5), float3(0.5), float3(1.0), float3(0.55, 0.6, 0.7))
    height = 0.25 + 0.25 * ridge(float2(p.x * 0.5 + time * 0.05, 0.0), 6)
    hills = 1.0 - smoothstep(height - 0.004, height, uv.y)
    ground = mix(float3(0.05, 0.06, 0.1), float3(0.3, 0.35, 0.45), uv.y / height)
    return float4(mix(sky, ground, hills), 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.noise"
```

## Cellular noise

`cellular` is the distance to the nearest of a random point per cell,
`cellular2` adds the second nearest (their difference outlines the cells),
and `voronoi` gives the distance to the cell's border and the offset to its
point. All take `time` to move the points. Left to right: `cellular`,
`cellular2`, `voronoi` with a color per cell.

```pyshader height="260"
from pyshader import *
from pyshader.stdlib.fragment.cellular import cellular, cellular2, voronoi
from pyshader.stdlib.fragment.random import hash32


def main(uv: float2, time: float, resolution: float2) -> float4:
    third = floor(uv.x * 3.0)
    st = uv * float2(resolution.x / resolution.y, 1.0) * 5.0
    color = float3(0.0)
    if third < 0.5:
        color = float3(cellular(st, time))
    elif third < 1.5:
        f = cellular2(st, time)
        color = float3(0.3, 0.7, 1.0) * (1.0 - smoothstep(0.0, 0.05, f.y - f.x))
    else:
        v = voronoi(st, time)
        tint = hash32(floor(st + v.yz))
        color = mix(tint * (0.5 + 0.5 * length(v.yz)), float3(1.0), 1.0 - smoothstep(0.0, 0.05, v.x))
    edge = step(0.004, abs(fract(uv.x * 3.0) - 0.0))
    return float4(color * edge, 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.cellular"
```
