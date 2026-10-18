# Shapes & SDF

Two ways to draw a shape. `shapes` gives masks, 1.0 inside and 0.0 outside,
in the 0..1 square: quick to use. `sdf` gives signed distance functions,
the distance to the shape's edge (negative inside), from which outlines,
glows, unions and smooth blends follow.

```py
from pyshader.stdlib.fragment.shapes import circle, star, rounded_rect
import pyshader.stdlib.fragment.sdf as sdf       # sdf.sd_box(p, half_size)
```

## Masks

Sixteen masks, one per cell, each turning slowly. Top row: `rect`,
`rounded_rect`, `circle`, `ring`, `ellipse`, `polygon`, `triangle` and
`hexagon`. Bottom row: `star`, `heart`, `crescent`, `lens`, `egg`, `pie`,
`flower` and `gear`.

```pyshader aspect="4:1"
from pyshader import *
from pyshader.stdlib.fragment.shapes import *
from pyshader.stdlib.fragment.matrix import rotate_around


def mask(i: float, st: float2, time: float) -> float:
    c = float2(0.5)
    if i < 0.5:
        return rect(st, float2(0.6, 0.4))
    if i < 1.5:
        return rounded_rect(st, c, float2(0.65, 0.45), 0.12, 0.005)
    if i < 2.5:
        return circle_smooth(st, c, 0.3, 0.005)
    if i < 3.5:
        return ring(st, c, 0.28, 0.06)
    if i < 4.5:
        return ellipse(st, c, float2(0.35, 0.2), 0.005)
    if i < 5.5:
        return polygon_smooth(st, c, 6, 0.28, 0.005)
    if i < 6.5:
        return triangle(st, c, 0.3, 0.005)
    if i < 7.5:
        return hexagon(st, c, 0.28, 0.005)
    if i < 8.5:
        return star(st, c, 5, 0.35, 0.6, 0.005)
    if i < 9.5:
        return heart(st, c, 0.6, 0.005)
    if i < 10.5:
        return crescent(st, c, 0.3, 0.45, 0.005)
    if i < 11.5:
        return lens(st, c, 0.3, 0.6, 0.005)
    if i < 12.5:
        return egg(st, c - float2(0.0, 0.08), 0.22, 0.005)
    if i < 13.5:
        return pie(st, c, 0.35, 2.0 + sin(time), 0.005)
    if i < 14.5:
        return flower(st, c, 5.0, 0.35)
    return gear(st, c, 10.0, 0.35)


def main(uv: float2, time: float) -> float4:
    grid = float2(8.0, 2.0)
    st = fract(uv * grid)
    cell = floor(uv * grid)
    i = cell.x + (1.0 - cell.y) * 8.0
    turned = rotate_around(st, 0.3 * sin(time + i), float2(0.5))
    m = mask(i, turned, time)
    shade = 0.07 + 0.03 * mod(cell.x + cell.y, 2.0)
    return float4(mix(float3(shade), float3(0.95, 0.75, 0.35), m), 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.shapes"
```

## Distance fields

A distance field drawn the usual way, warm inside and cool outside, with a
band every 0.05 and the edge in white. The shape changes every two seconds:
`sd_rounded_box`, `sd_star`, `sd_pentagram`, `sd_hexagram`, `sd_moon`,
`sd_egg`, `sd_heart`, `sd_horseshoe`, `sd_polygon` over a list of corners,
and `sd_bezier`.

```pyshader height="340"
from pyshader import *
import pyshader.stdlib.fragment.sdf as sdf
from pyshader.stdlib.fragment.coords import centered

ZIGZAG = [float2(-0.6, -0.4), float2(-0.2, 0.3), float2(0.0, -0.1), float2(0.2, 0.3), float2(0.6, -0.4)]


def shape(i: float, p: float2, time: float) -> float:
    if i < 0.5:
        return sdf.sd_rounded_box(p, float2(0.45, 0.3), float4(0.05, 0.2, 0.2, 0.05))
    if i < 1.5:
        return sdf.sd_star(p, 0.5, 7, 3.0)
    if i < 2.5:
        return sdf.sd_pentagram(p, 0.5)
    if i < 3.5:
        return sdf.sd_hexagram(p, 0.25)
    if i < 4.5:
        return sdf.sd_moon(p, 0.2 + 0.1 * sin(time), 0.45, 0.35)
    if i < 5.5:
        return sdf.sd_egg(p + float2(0.0, 0.2), 0.35, 0.1)
    if i < 6.5:
        return sdf.sd_heart(p * 1.6 + float2(0.0, 0.6)) / 1.6
    if i < 7.5:
        return sdf.sd_horseshoe(p, float2(cos(0.6), sin(0.6)), 0.35, float2(0.2, 0.07))
    if i < 8.5:
        return sdf.sd_polygon(ZIGZAG, p)
    return sdf.sd_bezier(p, float2(-0.6, -0.3), float2(0.0, 0.9 * sin(time)), float2(0.6, -0.3)) - 0.04


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = centered(uv, resolution)
    d = shape(mod(floor(time * 0.5), 10.0), p, time)
    color = float3(0.9, 0.6, 0.3) if d < 0.0 else float3(0.65, 0.85, 1.0)
    color *= 1.0 - exp(-6.0 * abs(d))
    color *= 0.8 + 0.2 * cos(125.0 * d)
    color = mix(color, float3(1.0), 1.0 - smoothstep(0.0, 0.01, abs(d)))
    return float4(color, 1.0)
```

## Combining shapes

Distance fields combine with plain arithmetic. `op_union` keeps both shapes,
`op_subtract` cuts one out of another, `op_intersect` keeps the overlap,
and the smooth versions round the seam over a distance `k`. `op_onion` turns
a shape into its outline, and `fill_smooth` / `stroke_smooth` turn a
distance into a mask. Left to right: union, smooth union, smooth subtract,
smooth intersect.

```pyshader height="240"
from pyshader import *
import pyshader.stdlib.fragment.sdf as sdf


def combine(i: float, a: float, b: float) -> float:
    if i < 0.5:
        return sdf.op_union(a, b)
    if i < 1.5:
        return sdf.op_smooth_union(a, b, 0.15)
    if i < 2.5:
        return sdf.op_smooth_subtract(a, b, 0.05)
    return sdf.op_smooth_intersect(a, b, 0.05)


def main(uv: float2, time: float, resolution: float2) -> float4:
    cells = 4.0
    i = floor(uv.x * cells)
    p = float2(fract(uv.x * cells) - 0.5, (uv.y - 0.5) * cells * resolution.y / resolution.x)
    a = sdf.sd_circle(p - float2(0.12 * sin(time), 0.0), 0.2)
    b = sdf.sd_box(p + float2(0.12 * sin(time), 0.0), float2(0.15))
    d = combine(i, a, b)
    color = float3(0.06, 0.06, 0.1)
    color = mix(color, float3(0.95, 0.6, 0.3), sdf.fill_smooth(d, 0.004))
    color = mix(color, float3(1.0), sdf.stroke_smooth(sdf.op_onion(d, 0.06), 0.006, 0.003))
    return float4(color, 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.sdf"
```
