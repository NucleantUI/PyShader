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

Twelve more, one per cell, the same way. Top row: `sd_ring`, `sd_lens`,
`sd_oriented_vesica`, `sd_bulging_egg`, `sd_blobby_cross` and `sd_cool_s`.
Bottom row: `sd_quadratic_circle`, `sd_stairs`, `sd_parabola_segment`,
`sd_hyperbola`, `sd_circle_wave` (a line, given a width) and `sd_arc_polygon`.
A shape made for a size of about 1 is drawn smaller by scaling p and the
distance alike: `sdf.sd_cool_s(p * 2.5) / 2.5`.

```pyshader aspect="3:1"
from pyshader import *
import pyshader.stdlib.fragment.sdf as sdf

SHIELD = [float3(0.0, -0.36, 0.22), float3(0.3, 0.26, -0.15), float3(-0.3, 0.26, 0.22)]


def shape(i: float, p: float2, time: float) -> float:
    if i < 0.5:
        a = 1.6 + 0.9 * sin(time)
        return sdf.sd_ring(p, float2(cos(a), sin(a)), 0.28, 0.08)
    if i < 1.5:
        return sdf.sd_lens(p, 0.38, 0.12 + 0.08 * sin(time))
    if i < 2.5:
        tip = 0.36 * float2(cos(0.5 * time), sin(0.5 * time))
        return sdf.sd_oriented_vesica(p, -tip, tip, 0.12)
    if i < 3.5:
        return sdf.sd_bulging_egg(p + float2(0.0, 0.18), 0.32, 0.17, 0.09, 0.55 + 0.3 * sin(time))
    if i < 4.5:
        return sdf.sd_blobby_cross(p * 2.6, 0.1 + 0.2 * sin(time)) / 2.6
    if i < 5.5:
        return sdf.sd_cool_s(p * 2.5) / 2.5
    if i < 6.5:
        return sdf.sd_quadratic_circle(p / 0.35) * 0.35
    if i < 7.5:
        return sdf.sd_stairs(p + float2(0.3, 0.25), float2(0.12, 0.1), 5.0)
    if i < 8.5:
        return sdf.sd_parabola_segment(p + float2(0.0, 0.2), 0.3, 0.4 + 0.1 * sin(time))
    if i < 9.5:
        return sdf.sd_hyperbola(p, 0.02 + 0.01 * sin(time), 0.3)
    if i < 10.5:
        return sdf.sd_circle_wave(p, 0.65 + 0.3 * sin(time), 0.1) - 0.02
    return sdf.sd_arc_polygon(SHIELD, p)


def main(uv: float2, time: float, resolution: float2) -> float4:
    grid = float2(6.0, 2.0)
    cell = floor(uv * grid)
    i = cell.x + (1.0 - cell.y) * 6.0
    p = (fract(uv * grid) - 0.5) * float2(1.0, resolution.y * grid.x / (resolution.x * grid.y))
    d = shape(i, p, time)
    color = float3(0.9, 0.6, 0.3) if d < 0.0 else float3(0.65, 0.85, 1.0)
    color *= 1.0 - exp(-8.0 * abs(d))
    color *= 0.8 + 0.2 * cos(160.0 * d)
    color = mix(color, float3(1.0), 1.0 - smoothstep(0.0, 0.008, abs(d)))
    return float4(color, 1.0)
```

## Corners joined by arcs

`sd_arc_polygon` takes the corners of an outline as `float3(x, y, bulge)`:
the bulge bends the edge from that corner to the next into a circular arc.
0 keeps it straight, 1 makes it a half circle, 0.41 a quarter, more than 1
more than half; a positive bulge bows to the right of the edge's direction,
outward when the corners run counterclockwise, and a negative one inward.
Any outline of lines and arcs is one call, and its distance is exact. Here
each edge's bulge swings between -0.6 and 0.6, out of step with the others:

```pyshader height="300"
from pyshader import *
import pyshader.stdlib.fragment.sdf as sdf
from pyshader.stdlib.fragment.coords import centered


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = centered(uv, resolution)
    corners = [
        float3(-0.5, -0.35, 0.6 * sin(time)),
        float3(0.5, -0.35, 0.6 * sin(time + 1.5)),
        float3(0.5, 0.35, 0.6 * sin(time + 3.0)),
        float3(-0.5, 0.35, 0.6 * sin(time + 4.5)),
    ]
    d = sdf.sd_arc_polygon(corners, p)
    color = float3(0.9, 0.6, 0.3) if d < 0.0 else float3(0.65, 0.85, 1.0)
    color *= 1.0 - exp(-6.0 * abs(d))
    color *= 0.8 + 0.2 * cos(125.0 * d)
    color = mix(color, float3(1.0), 1.0 - smoothstep(0.0, 0.01, abs(d)))
    # The corners, as dots.
    dot_distance = 1.0
    for i in range(4):
        dot_distance = min(dot_distance, length(p - corners[i].xy))
    color = mix(color, float3(0.1), 1.0 - smoothstep(0.04, 0.05, dot_distance))
    color = mix(color, float3(1.0), 1.0 - smoothstep(0.025, 0.035, dot_distance))
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

## Repetition

The repetition operators change the point, not the distance: a shape drawn at
the point they return appears in every cell. `op_repeat` fills a grid,
`op_repeat_limited` stops after `count` copies to each side (a row with
`count = (n, 0)`), and `op_repeat_polar` turns one copy, placed along +x,
`count` times around the origin. Left to right: each of them.

```pyshader aspect="3:1"
from pyshader import *
import pyshader.stdlib.fragment.sdf as sdf
from pyshader.stdlib.fragment.matrix import rotate2d


def shape(i: float, p: float2, time: float) -> float:
    if i < 0.5:
        q = sdf.op_repeat(p + float2(0.05 * time, 0.0), float2(0.14))
        return sdf.sd_rounded_box(q, float2(0.04), float4(0.015))
    if i < 1.5:
        q = sdf.op_repeat_limited(p, float2(0.16, 1.0), float2(2.0, 0.0))
        return sdf.sd_circle(q, 0.05 + 0.015 * sin(time))
    q = sdf.op_repeat_polar(rotate2d(0.4 * time) * p, 8.0)
    return sdf.sd_box(q - float2(0.28, 0.0), float2(0.08, 0.025)) - 0.01


def main(uv: float2, time: float, resolution: float2) -> float4:
    cells = 3.0
    i = floor(uv.x * cells)
    p = float2(fract(uv.x * cells) - 0.5, (uv.y - 0.5) * cells * resolution.y / resolution.x)
    d = shape(i, p, time)
    color = float3(0.06, 0.06, 0.1)
    color = mix(color, float3(0.35, 0.75, 0.95), sdf.fill_smooth(d, 0.003))
    color = mix(color, float3(1.0), sdf.stroke_smooth(d, 0.006, 0.002))
    return float4(color, 1.0)
```

## Building new shapes

A new shape is a few of these put together: the operators join, cut and
round them, repetition copies them, and `abs(p.x)` mirrors one half onto the
other. Each cell below is one short function. Top row: a keyhole (a circle on
a trapezoid), a flower (one petal repeated six times around a center), a gear
(a box repeated ten times around a disk, a hole cut out), a shield (one
`sd_arc_polygon` with a star cut out). Bottom row: a padlock (`sd_ring` on a
rounded box, a small keyhole cut out), a speech bubble (a rounded box and a
triangle blended, a row of dots cut out), a butterfly (two circles
for a wing and a segment for an antenna, drawn for the right half and
mirrored, a gap cut around a capsule body) and a strap (a rounded box, a row
of holes).

```pyshader aspect="2:1"
from pyshader import *
import pyshader.stdlib.fragment.sdf as sdf

SHIELD = [float3(0.0, -0.36, 0.22), float3(0.3, 0.26, -0.15), float3(-0.3, 0.26, 0.22)]


def keyhole(p: float2) -> float:
    return sdf.op_union(sdf.sd_circle(p - float2(0.0, 0.1), 0.14),
                        sdf.sd_trapezoid(p + float2(0.0, 0.12), 0.13, 0.05, 0.17))


def flower(p: float2, time: float) -> float:
    petal = sdf.sd_circle(sdf.op_repeat_polar(p, 6.0) - float2(0.2, 0.0), 0.1 + 0.02 * sin(time))
    return sdf.op_smooth_union(petal, sdf.sd_circle(p, 0.12), 0.04)


def gear(p: float2, time: float) -> float:
    tooth = sdf.sd_box(sdf.op_repeat_polar(p, 10.0) - float2(0.28, 0.0), float2(0.05, 0.035)) - 0.01
    body = sdf.op_union(sdf.sd_circle(p, 0.26), tooth)
    return sdf.op_subtract(body, sdf.sd_circle(p, 0.08 + 0.02 * sin(time)))


def shield(p: float2) -> float:
    return sdf.op_subtract(sdf.sd_arc_polygon(SHIELD, p), sdf.sd_star(p - float2(0.0, 0.03), 0.13, 5, 2.5))


def padlock(p: float2) -> float:
    body = sdf.sd_rounded_box(p + float2(0.0, 0.1), float2(0.22, 0.17), float4(0.04))
    shackle = sdf.sd_ring(p - float2(0.0, 0.07), float2(0.0, 1.0), 0.14, 0.05)
    return sdf.op_subtract(sdf.op_union(body, shackle), keyhole((p + float2(0.0, 0.1)) * 2.8) / 2.8)


def bubble(p: float2) -> float:
    box = sdf.sd_rounded_box(p - float2(0.0, 0.06), float2(0.32, 0.2), float4(0.1))
    tail = sdf.sd_triangle(p, float2(-0.14, -0.08), float2(0.02, -0.08), float2(-0.22, -0.32))
    dots = sdf.sd_circle(sdf.op_repeat_limited(p - float2(0.0, 0.06), float2(0.14, 1.0), float2(1.0, 0.0)), 0.035)
    return sdf.op_subtract(sdf.op_smooth_union(box, tail, 0.03), dots)


def butterfly(p: float2, time: float) -> float:
    q = float2(abs(p.x), p.y)                     # the right half, mirrored to the left
    flap = 0.75 + 0.25 * abs(sin(3.0 * time))
    w = float2(q.x / flap, q.y)
    wings = sdf.op_union(sdf.sd_circle(w - float2(0.19, 0.1), 0.14), sdf.sd_circle(w - float2(0.14, -0.13), 0.1)) * flap
    body = sdf.sd_uneven_capsule(p + float2(0.0, 0.2), 0.035, 0.045, 0.36)
    antenna = sdf.sd_segment(q, float2(0.02, 0.16), float2(0.1, 0.3)) - 0.012
    return sdf.op_union(sdf.op_union(sdf.op_subtract(wings, body - 0.025), body), antenna)


def strap(p: float2) -> float:
    plate = sdf.sd_rounded_box(p, float2(0.38, 0.12), float4(0.06))
    holes = sdf.sd_circle(sdf.op_repeat_limited(p, float2(0.14, 1.0), float2(2.0, 0.0)), 0.035)
    return sdf.op_subtract(plate, holes)


def shape(i: float, p: float2, time: float) -> float:
    if i < 0.5:
        return keyhole(p)
    if i < 1.5:
        return flower(p, time)
    if i < 2.5:
        return gear(p, time)
    if i < 3.5:
        return shield(p)
    if i < 4.5:
        return padlock(p)
    if i < 5.5:
        return bubble(p)
    if i < 6.5:
        return butterfly(p, time)
    return strap(p)


def main(uv: float2, time: float, resolution: float2) -> float4:
    grid = float2(4.0, 2.0)
    cell = floor(uv * grid)
    i = cell.x + (1.0 - cell.y) * 4.0
    p = (fract(uv * grid) - 0.5) * float2(1.0, resolution.y * grid.x / (resolution.x * grid.y))
    d = shape(i, p, time)
    shade = 0.07 + 0.03 * mod(cell.x + cell.y, 2.0)
    color = mix(float3(shade), float3(0.95, 0.75, 0.35), sdf.fill_smooth(d, 0.003))
    color = mix(color, float3(1.0), sdf.stroke_smooth(d, 0.006, 0.002))
    return float4(color, 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.sdf"
```
