# Vertex helpers

For the vertex stage of the [graphics target](../targets/graphics.md): 4x4
transforms and projections, quads built from `vertex_index` with no vertex
buffer, conversions between pixels and clip space, and deformations.

```py
from pyshader.stdlib.vertex.transform import perspective, look_at, rotate, UP
from pyshader.stdlib.vertex.quad import quad_corner, grid_position
from pyshader.stdlib.vertex.deform import wave, twist
```

The projections are right-handed and produce y-up clip space with depth
0..1, which is what the graphics target expects.

## Quads and transforms

64 instances of one quad, 6 vertices each. `quad_corner(vertex_index)` gives
each vertex its corner, `grid_position(instance_index, …)` places the
instance, and each turns in 3D with `rotate`, seen through `look_at` and
`perspective`. The fragment stage draws a rounded box with the
[sdf](shapes.md) module.

```pyshader vertices="6" instances="64" height="340"
from pyshader import *
from pyshader.stdlib.vertex.quad import quad_corner, grid_position
from pyshader.stdlib.vertex.transform import perspective, look_at, rotate, translate, UP
from pyshader.stdlib.fragment.sdf import sd_rounded_box, fill_smooth


class Tile:
    position: float4
    local: float2
    seed: float


def vertex(vertex_index: int, instance_index: int, time: float, resolution: float2) -> Tile:
    corner = quad_corner(vertex_index)
    center = grid_position(instance_index, 8, float2(1.2)) - float2(4.2)
    seed = float(instance_index) / 64.0
    model = translate(float3(center, 0.0)) * rotate(float3(1.0, 1.0, 0.0), time + seed * 6.28)
    view = look_at(float3(0.0, -6.0, 9.0), float3(0.0), UP)
    projection = perspective(radians(50.0), resolution.x / resolution.y, 0.1, 50.0)
    return Tile(projection * view * model * float4(corner * 0.45, 0.0, 1.0), local=corner, seed=seed)


def fragment(local: float2, seed: float) -> float4:
    shape = fill_smooth(sd_rounded_box(local, float2(0.8), float4(0.2)), 0.03)
    return float4(float3(0.3 + seed * 0.7, 0.5, 1.0 - seed) * shape, shape)
```

```pyshader-api module="pyshader.stdlib.vertex.transform"
```

```pyshader-api module="pyshader.stdlib.vertex.quad"
```

## Deformations

A 32 by 32 grid of quads lying flat, lifted by `wave` and by a `ripple`
spreading from the middle, then `twist`ed around the vertical axis. The
fragment stage shades by height.

```pyshader vertices="6" instances="1024" height="340"
from pyshader import *
from pyshader.stdlib.vertex.quad import quad_uv, grid_cell
from pyshader.stdlib.vertex.transform import perspective, look_at, UP
from pyshader.stdlib.vertex.deform import wave, ripple, twist


class Surface:
    position: float4
    height: float


def vertex(vertex_index: int, instance_index: int, time: float, resolution: float2) -> Surface:
    cell = float2(grid_cell(instance_index, 32)) + quad_uv(vertex_index)
    p = float3(cell.x / 32.0 * 4.0 - 2.0, 0.0, cell.y / 32.0 * 4.0 - 2.0)
    p = wave(p, time, 0.12, 3.0, 2.0)
    p = ripple(p, float2(0.0), time, 0.1, 8.0, 4.0)
    p = twist(p, 2.0)
    view = look_at(float3(0.0, 2.5, 4.0), float3(0.0, -0.2, 0.0), UP)
    projection = perspective(radians(45.0), resolution.x / resolution.y, 0.1, 50.0)
    return Surface(projection * view * float4(p, 1.0), height=p.y)


def fragment(height: float) -> float4:
    t = clamp(height * 2.5 + 0.5, 0.0, 1.0)
    return float4(mix(float3(0.1, 0.2, 0.6), float3(0.6, 0.9, 1.0), t), 1.0)
```

```pyshader-api module="pyshader.stdlib.vertex.deform"
```

## Pixels and clip space

`pixel_to_clip` places a vertex by its pixel position (top left origin, y
down, the way a view measures), and `pixel_size_to_clip` turns a size in
pixels into one in clip space. `billboard` turns a quad corner to face the
camera of a view matrix.

```pyshader-api module="pyshader.stdlib.vertex.space"
```
