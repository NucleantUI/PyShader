# Surfaces & materials

`surface` and `material` are what things are made of. A material gives the
`Surface` of a point (its color, the way it faces, how rough and how
metallic it is), and `surface.shade` lights it the way physically based
renderers do, so plastic stays plastic and gold stays gold under any light.

```py
import pyshader.stdlib.fragment.material as material   # material.marble(p, n, base, vein)
import pyshader.stdlib.fragment.surface as surface     # surface.shade(s, light, view, light_color)
```

Directions are unit vectors with x right, y up and z toward the viewer, so
the view is `float3(0.0, 0.0, 1.0)` and a flat shape gets its normal from
`light.sphere_normal` or `light.bevel_normal`. Colors are linear: light adds
up past 1, so tone map the sum (`light.tonemap_aces`) and encode it
(`color.linear_to_srgb`) at the end.

## Light on a surface

`shade(s, light, view, light_color)` is one light's share: a diffuse part
that scatters the surface's own color, and a highlight. Roughness spreads the
highlight from a sharp point to a soft sheen; a metal (bottom row, `GOLD`)
has no diffuse part and colors its highlight. Together they never send out
more light than arrives. `shade_ambient(s, view, ambient, reflected)` adds the
surroundings: `ambient` scattered, `reflected` mirrored, what lies in the
direction `reflect(-view, s.normal)`. A metal shows little else, so give it
something to reflect.

```pyshader aspect="3:1"
from pyshader import *
import pyshader.stdlib.fragment.light as light
import pyshader.stdlib.fragment.material as material
from pyshader.stdlib.fragment.surface import shade, shade_ambient
from pyshader.stdlib.fragment.color import linear_to_srgb

VIEW = float3(0.0, 0.0, 1.0)


def surroundings(r: float3) -> float3:
    """A dim floor, a bright warm horizon, a blue sky above."""
    up = r.y + 0.3 * r.z
    sky = mix(float3(1.0, 0.85, 0.65), float3(0.35, 0.5, 0.8), smoothstep(0.1, 0.9, up))
    return mix(float3(0.08, 0.07, 0.06), sky, smoothstep(-0.25, 0.05, up))


def main(uv: float2, time: float, resolution: float2) -> float4:
    grid = float2(6.0, 2.0)
    cell = floor(uv * grid)
    p = (fract(uv * grid) - 0.5) * float2(resolution.x / grid.x, resolution.y / grid.y) / (resolution.y / grid.y)
    roughness = 0.05 + 0.95 * cell.x / (grid.x - 1.0)
    n = light.sphere_normal(p, 0.4)
    s = material.plastic(n, float3(0.7, 0.05, 0.04), roughness)
    if cell.y < 0.5:
        s = material.metal(n, material.GOLD, roughness)
    a = time * 0.6
    l = normalize(float3(cos(a), 0.6 + 0.3 * sin(a), 0.8))
    c = shade(s, l, VIEW, float3(3.0)) + shade_ambient(s, VIEW, float3(0.06), surroundings(reflect(-VIEW, n)))
    disk = 1.0 - smoothstep(0.39, 0.4, length(p))
    return float4(linear_to_srgb(light.tonemap_aces(mix(float3(0.02), c, disk))), 1.0)
```

The pieces are there to build other models from: `ggx` (how many
microfacets face a direction), `visibility` (how many of them the others hide),
`fresnel_schlick` and `fresnel_roughness` (how much is reflected at an angle),
`reflectance` (a surface's reflectance head on), `bump` (a normal tilted by a
height field's slope), `with_normal` and `blend` (rust over metal, wet over
dry, moss over stone).

## Materials

Each material takes `p`, where the point is on it (scale it for finer or
coarser grain), and `n`, the way the shape faces, which its bumps and grooves
tilt. One light and one shading model for all sixteen: plastic, rubber,
ceramic and glass; gold, brushed aluminum, copper and rust; rock, granite,
marble and concrete; sand, wood, leather and fabric.

```pyshader aspect="1:1"
from pyshader import *
from pyshader.stdlib.fragment import sdf, light, material
from pyshader.stdlib.fragment.color import linear_to_srgb
from pyshader.stdlib.fragment.surface import shade, shade_ambient

VIEW = float3(0.0, 0.0, 1.0)
SUN = float3(3.2, 3.0, 2.8)
SKY = float3(0.10, 0.12, 0.16)


def tile_distance(p: float2) -> float:
    return sdf.sd_rounded_box(p, float2(0.78), float4(0.22))


def backdrop(q: float2) -> float3:
    c = mod(floor(q.x * 10.0) + floor(q.y * 10.0), 2.0)
    return mix(float3(0.04, 0.06, 0.1), float3(0.85, 0.78, 0.6), c)


def surroundings(r: float3) -> float3:
    up = r.y + 0.3 * r.z
    sky = mix(float3(1.0, 0.85, 0.65), float3(0.35, 0.5, 0.8), smoothstep(0.1, 0.9, up))
    return mix(float3(0.08, 0.07, 0.06), sky, smoothstep(-0.25, 0.05, up))


def tile(k: int, m: float2, n: float3, l: float3, q: float2) -> float3:
    if k == 3:
        behind = backdrop(q + material.refraction_offset(n, material.GLASS_IOR, 0.12))
        return material.glass(behind, n, l, SUN, surroundings(reflect(-VIEW, n)), float3(0.8, 0.95, 0.9), material.GLASS_IOR, 1.0)
    s = material.plastic(n, float3(0.75, 0.08, 0.06), 0.3)
    if k == 1:
        s = material.rubber(m, n, float3(0.12, 0.12, 0.13))
    if k == 2:
        s = material.ceramic(n, float3(0.12, 0.3, 0.7))
    if k == 4:
        s = material.metal(n, material.GOLD, 0.2)
    if k == 5:
        s = material.brushed_metal(m, n, material.ALUMINUM, 0.4)
    if k == 6:
        s = material.metal(n, material.COPPER, 0.35)
    if k == 7:
        s = material.rust(m, n, material.IRON, 0.55)
    if k == 8:
        s = material.rock(m, n)
    if k == 9:
        s = material.granite(m, n)
    if k == 10:
        s = material.marble(m, n, float3(0.88, 0.86, 0.82), float3(0.22, 0.24, 0.28))
    if k == 11:
        s = material.concrete(m, n)
    if k == 12:
        s = material.sand(m * 2.0, n, float3(0.76, 0.6, 0.4))
    if k == 13:
        s = material.wood(m, n, float3(0.62, 0.4, 0.2), float3(0.3, 0.16, 0.07))
    if k == 14:
        s = material.leather(m * 3.0, n, float3(0.32, 0.15, 0.08))
    if k == 15:
        s = material.fabric(m * 6.0, n, float3(0.15, 0.25, 0.55))
    return shade(s, l, VIEW, SUN) + shade_ambient(s, VIEW, SKY, surroundings(reflect(-VIEW, s.normal)))


def main(uv: float2, time: float) -> float4:
    cell = floor(uv * 4.0)
    k = int(cell.x + (3.0 - cell.y) * 4.0)
    p = fract(uv * 4.0) * 2.0 - 1.0
    d = tile_distance(p)
    e = 0.002
    slope = float2(tile_distance(p + float2(e, 0.0)) - tile_distance(p - float2(e, 0.0)),
                   tile_distance(p + float2(0.0, e)) - tile_distance(p - float2(0.0, e)))
    n = light.bevel_normal(d, normalize(slope + float2(0.0001)), 0.2)
    a = time * 0.5
    l = normalize(float3(cos(a) * 0.9, sin(a) * 0.9, 0.75))
    under = (backdrop(uv * 1.2) * 0.15 + float3(0.02)) * (1.0 - 0.7 * light.drop_shadow(tile_distance(p + l.xy * 0.08), 0.06))
    c = mix(under, tile(k, p * 1.5 + cell * 3.7, n, l, uv * 1.2), 1.0 - smoothstep(-0.01, 0.01, d))
    return float4(linear_to_srgb(light.tonemap_aces(c)), 1.0)
```

| Material | Takes | Looks like |
|---|---|---|
| `plastic(n, color, roughness)` | | its color under a white highlight |
| `ceramic(n, color)` | | glazed: glossy, a clear rim |
| `rubber(p, n, color)` | | matte, a dim wide highlight, a faint grain |
| `metal(n, color, roughness)` | `GOLD`, `SILVER`, `COPPER`, `BRASS`, `ALUMINUM`, `IRON`, `CHROMIUM` | no diffuse, a colored highlight |
| `brushed_metal(p, n, color, angle)` | | streaks along `angle`, the highlight smeared along them |
| `rust(p, n, color, amount)` | `amount` 0 clean … 1 all rust | rough orange-brown patches eating into the metal |
| `rock(p, n)` | | ridged, cracked, grey-brown |
| `granite(p, n)` | | grey, pink and black crystals under a gloss |
| `marble(p, n, base, vein)` | | winding veins, polished |
| `concrete(p, n)` | | mottled grey, fine grit, small pits |
| `sand(p, n, color)` | | wind ripples and grains, very matte |
| `wood(p, n, light, dark)` | | warped growth rings and grain, satin |
| `leather(p, n, color)` | | pebbled cells, dark creases |
| `fabric(p, n, color)` | | threads woven over and under, one per unit of `p` |
| `ice(p, n)` | | clear, pale blue, white fractures; seen through as glass |

## Glass and water

Glass is seen through. `refraction_offset(n, ior, thickness)` is how far the
background behind a pane facing `n` shifts as the light bends going in: sample
the background there and hand it to `glass`, which tints it (`absorb`, deeper
color through more glass), adds what the pane mirrors by Fresnel (little head
on, nearly all at the rim) and the light's highlight. Water is the same with
`WATER_IOR` and a normal from `water_normal`, ripples drifting with time.

```pyshader aspect="2:1"
from pyshader import *
import pyshader.stdlib.fragment.light as light
import pyshader.stdlib.fragment.material as material
from pyshader.stdlib.fragment.cellular import cellular2
from pyshader.stdlib.fragment.noise import fbm
from pyshader.stdlib.fragment.color import linear_to_srgb


def surroundings(r: float3) -> float3:
    up = r.y + 0.3 * r.z
    sky = mix(float3(1.0, 0.85, 0.65), float3(0.35, 0.5, 0.8), smoothstep(0.1, 0.9, up))
    return mix(float3(0.08, 0.07, 0.06), sky, smoothstep(-0.25, 0.05, up))


def stripes(q: float2, time: float) -> float3:
    """What stands behind the lens: drifting stripes."""
    s = step(0.5, fract((q.x + q.y * 0.4) * 6.0 + time * 0.2))
    return mix(float3(0.9, 0.3, 0.2), float3(0.95, 0.9, 0.8), s)


def pebbles(q: float2) -> float3:
    """The bottom under the water: stones of varied tone, dark gaps between them."""
    c = cellular2(q * 5.0, 0.0)
    gap = smoothstep(0.0, 0.12, c.y - c.x)
    tone = fbm(q * 4.0, 3)
    return mix(float3(0.42, 0.34, 0.24), float3(0.78, 0.74, 0.66), tone) * (0.15 + 0.85 * gap)


def main(uv: float2, time: float, resolution: float2) -> float4:
    q = float2(uv.x * resolution.x / resolution.y, uv.y)
    sun = float3(4.0)
    # High and behind the viewer: the ripples catch it.
    l = normalize(float3(0.25, 0.35, 1.0))
    if uv.x < 0.5:
        # A glass lens over the stripes.
        p = q - float2(0.5, 0.5)
        n = light.sphere_normal(p, 0.36)
        behind = stripes(q + material.refraction_offset(n, material.GLASS_IOR, 0.35), time)
        c = material.glass(behind, n, l, sun, surroundings(reflect(float3(0.0, 0.0, -1.0), n)),
                           float3(0.85, 0.95, 0.92), material.GLASS_IOR, 1.0)
        c = mix(stripes(q, time) * 0.5, c, 1.0 - smoothstep(0.355, 0.36, length(p)))
    else:
        # Rippling water over pebbles.
        n = material.water_normal(q * 3.0, time, 0.25)
        behind = pebbles(q + material.refraction_offset(n, material.WATER_IOR, 0.4))
        c = material.glass(behind, n, l, sun, surroundings(reflect(float3(0.0, 0.0, -1.0), n)),
                           float3(0.55, 0.8, 0.75), material.WATER_IOR, 1.0)
    return float4(linear_to_srgb(light.tonemap_aces(c)), 1.0)
```

On the compute and graphics targets, which have
[textures](../targets/compute.md#textures), `glass_over` and
`frosted_glass_over` sample a texture behind the pane themselves; frost
blurs it over a disk of `frost` in uv:

```py
def main(uv: float2, time: float, background: Texture) -> float4:
    p = uv - 0.5
    d = sdf.sd_rounded_box(p, float2(0.3, 0.2), float4(0.05))
    n = light.bevel_normal(d, normalize(p + float2(0.0001)), 0.04)
    pane = material.frosted_glass_over(background, uv, n, l, float3(3.0), float3(0.3),
                                       float3(0.95), material.GLASS_IOR, 0.05, 0.02)
    return float4(mix(background(uv).rgb, pane, 1.0 - step(0.0, d)), 1.0)
```

`ice(p, n)` is the surface inside: put it over its background with `glass`
and `ICE_IOR`, then light its fractures with `surface.shade`.
