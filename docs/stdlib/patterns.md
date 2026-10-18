# Coordinates, matrices & patterns

Moving the coordinates instead of the shape: center them, turn them, and
repeat them across the plane. Whatever is drawn in the result follows.

```py
from pyshader.stdlib.fragment.coords import centered, to_polar
from pyshader.stdlib.fragment.matrix import rotate2d, rotate_around
from pyshader.stdlib.fragment.pattern import tile, brick_tile, truchet
```

## Coordinates and matrices

`centered` makes the middle of the view (0, 0), -1..1 across its shorter
side, so a circle stays round at any size. `to_polar` gives the radius and
the angle around it; here they draw a spiral. `rotate2d(angle) * p` turns a
point, and the boxes turn with `rotate_around` about the center of each copy.

```pyshader height="300"
from pyshader import *
from pyshader.stdlib.fragment.coords import centered, to_polar
from pyshader.stdlib.fragment.matrix import rotate2d, rotate_around
from pyshader.stdlib.fragment.pattern import tile
from pyshader.stdlib.fragment.shapes import rect


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = rotate2d(time * 0.2) * centered(uv, resolution)
    polar = to_polar(p)
    spiral = 0.5 + 0.5 * sin(polar.x * 30.0 - polar.y * 3.0 - time * 3.0)
    st = rotate_around(tile(p * 0.5 + 0.5, 6.0), time, float2(0.5))
    box = rect(st, float2(0.4))
    color = mix(float3(0.05, 0.05, 0.12), float3(0.3, 0.5, 1.0), spiral * smoothstep(1.2, 0.2, polar.x))
    return float4(mix(color, float3(1.0, 0.8, 0.4), box * 0.8), 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.coords"
```

```pyshader-api module="pyshader.stdlib.fragment.matrix"
```

## Patterns

One motif, four patterns, clockwise from the top left: `brick_tile` with
moving rows, `mirror_tile`, `rotate_tile_pattern`, and a `truchet` maze that
reshuffles every two seconds.

```pyshader height="320"
from pyshader import *
from pyshader.stdlib.fragment.pattern import brick_tile, mirror_tile, rotate_tile_pattern, truchet, tile, checker
from pyshader.stdlib.fragment.shapes import rect, circle_smooth


def main(uv: float2, time: float) -> float4:
    quadrant = floor(uv * 2.0)
    q = fract(uv * 2.0)
    color = float3(0.06, 0.06, 0.1)
    if quadrant.y > 0.5 and quadrant.x < 0.5:
        st = brick_tile(q + float2(time * 0.1, 0.0), 5.0, 0.5)
        color = mix(color, float3(0.8, 0.35, 0.25), rect(st, float2(0.9, 0.8)))
    elif quadrant.y > 0.5:
        st = mirror_tile(q, 4.0)
        color = mix(color, float3(0.3, 0.7, 0.9), circle_smooth(st, float2(0.0), 0.8, 0.02) - circle_smooth(st, float2(0.0), 0.5, 0.02))
    elif quadrant.x > 0.5:
        st = truchet(q, 6.0, floor(time * 0.5))
        arc = abs(length(st) - 0.5)
        arc = min(arc, abs(length(st - 1.0) - 0.5))
        color = mix(color, float3(0.95, 0.8, 0.4), 1.0 - smoothstep(0.06, 0.09, arc))
    else:
        st = rotate_tile_pattern(tile(q, 3.0))
        tri = step(st.x, st.y)
        color = mix(float3(0.15, 0.1, 0.25), float3(0.6, 0.4, 0.9), tri)
    color *= 0.9 + 0.1 * checker(uv, 2.0)
    return float4(color, 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.pattern"
```
