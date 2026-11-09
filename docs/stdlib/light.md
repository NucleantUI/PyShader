# Light, glow & shadow

`light` makes things shine: glows from any shape's distance field, neon
tubes, LEDs and LED rings, shading that makes a flat shape look round, soft
shadows, and the tone mapping that turns light added up past 1 into colors.

```py
import pyshader.stdlib.fragment.light as light   # light.neon(d, color, width, radius)
import pyshader.stdlib.fragment.sdf as sdf
```

Most functions take a distance: from a light's center, or to a shape's edge
as `sdf` measures it (negative inside). So every shape in `sdf` can glow, and
lights add: sum them, then tone map the sum once at the end.

## Glowing shapes

One shape's distance, four ways to light it. Left to right: `glow`, lit from
inside with a halo; `glow_inner`, light along the inside of the edge;
`glow_edge`, the outline itself glowing; `neon`, a tube with a white-hot core,
here flickering with `flicker`. Each is tone mapped with `tonemap_exposure`.

```pyshader aspect="4:1"
from pyshader import *
import pyshader.stdlib.fragment.light as light
import pyshader.stdlib.fragment.sdf as sdf


def shine(i: float, p: float2, time: float) -> float3:
    if i < 0.5:
        d = sdf.sd_star(p, 0.24, 5, 2.5)
        return float3(1.0, 0.55, 0.15) * light.glow(d, 0.03 + 0.012 * sin(time))
    if i < 1.5:
        d = sdf.sd_heart(p * 2.4 + float2(0.0, 0.55)) / 2.4
        return float3(1.0, 0.2, 0.45) * 1.6 * light.glow_inner(d, 0.035)
    if i < 2.5:
        d = sdf.sd_circle(p, 0.26)
        return float3(0.3, 0.7, 1.0) * light.glow_edge(d, 0.012 + 0.006 * sin(2.0 * time))
    d = sdf.sd_cool_s(p * 2.6) / 2.6
    return light.neon(d, float3(0.7, 0.3, 1.0), 0.008, 0.02) * light.flicker(time, 1.0, 0.6)


def main(uv: float2, time: float, resolution: float2) -> float4:
    cells = 4.0
    i = floor(uv.x * cells)
    p = float2(fract(uv.x * cells) - 0.5, (uv.y - 0.5) * cells * resolution.y / resolution.x)
    c = float3(0.02, 0.02, 0.04) + shine(i, p, time)
    return float4(light.tonemap_exposure(c, 1.2), 1.0)
```

## Neon and light tubes

`neon` follows any edge. `segment_light` is a straight tube that really
lights its surroundings: every point along it an inverse-square light, added
up exactly, so a long tube throws a wide, even glow and a short one a round
one. A sign: a neon heart outline, and tubes under it.

```pyshader height="320"
from pyshader import *
import pyshader.stdlib.fragment.light as light
import pyshader.stdlib.fragment.sdf as sdf
from pyshader.stdlib.fragment.coords import centered


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = centered(uv, resolution)
    heart = sdf.sd_heart((p - float2(0.0, -0.25)) * 1.6) / 1.6
    c = light.neon(heart, float3(1.0, 0.15, 0.4), 0.012, 0.03) * light.flicker(time, 2.0, 0.4)
    tubes = light.segment_light(p, float2(-0.9, -0.62), float2(-0.1, -0.62), 0.02)
    tubes += light.segment_light(p, float2(0.1, -0.62), float2(0.9, -0.62), 0.02)
    c += float3(0.2, 0.9, 1.0) * tubes * (0.6 + 0.4 * light.breathe(time, 2.5))
    # A brick wall the light falls on.
    row = floor(p.y * 10.0)
    brick = fract(float2(p.x * 5.0 + 0.5 * mod(row, 2.0), p.y * 10.0))
    mortar = step(0.06, brick.x) * step(0.1, brick.y)
    wall = float3(0.16, 0.1, 0.08) * (0.35 + 0.65 * mortar)
    return float4(light.tonemap_aces(wall * (0.15 + 6.0 * c) + c), 1.0)
```

## LEDs and LED rings

`led` is one LED: a white-hot spot in a colored halo. `led_ring_index` tells
which of a ring's LEDs is nearest a point, and `led_ring_position` where any
LED sits, so a ring is drawn by lighting the nearest LED and its two
neighbours, whose halos overlap it. Each LED's color and brightness is yours
to pick by its index: here `chase` runs a comet around 24 LEDs, colored by
index. Right: a ring with no LEDs, a light guide. Its edge glows
(`glow_edge`) with a comet that brightens by angle, and its inside
`breathe`s.

```pyshader aspect="2:1"
from pyshader import *
import pyshader.stdlib.fragment.light as light
import pyshader.stdlib.fragment.sdf as sdf
from pyshader.stdlib.fragment.color import hsb_to_rgb


def led_ring(p: float2, time: float) -> float3:
    count = 24.0
    i0 = light.led_ring_index(p, count)
    c = float3(0.0)
    for k in range(3):
        i = mod(i0 + float(k) - 1.0, count)
        level = light.chase(i, count, time * 9.0, 10.0)
        tint = hsb_to_rgb(float3(i / count, 0.85, 1.0))
        c += (0.03 + level) * light.led(p - light.led_ring_position(i, count, 0.33), tint, 0.012, 0.014)
    return c


def light_guide(p: float2, time: float) -> float3:
    ring = sdf.op_onion(sdf.sd_circle(p, 0.3), 0.03)
    a = atan2(p.y, p.x)
    behind = mod(2.5 * time - a, 2.0 * PI) / (2.0 * PI)
    comet = pow(1.0 - behind, 6.0)
    tint = float3(0.25, 0.7, 1.0)
    c = tint * light.glow_edge(ring, 0.006) * (0.08 + comet)
    c += tint * 0.5 * light.glow_inner(sdf.sd_circle(p, 0.28), 0.05) * light.breathe(time, 3.0)
    return c


def main(uv: float2, time: float, resolution: float2) -> float4:
    cells = 2.0
    i = floor(uv.x * cells)
    p = float2(fract(uv.x * cells) - 0.5, (uv.y - 0.5) * cells * resolution.y / resolution.x)
    c = led_ring(p, time) if i < 0.5 else light_guide(p, time)
    return float4(light.tonemap_exposure(c + float3(0.015), 1.0), 1.0)
```

## Shading

A flat shape looks round when each pixel knows which way its surface faces.
`sphere_normal` gives that for a ball (an LED's dome, a button, a planet);
`bevel_normal` for any shape whose edge is rounded over a width, from its
distance and the direction the distance grows in. `lambert` lights it,
`blinn_phong` adds the shine of the light, `fresnel` the light caught along
the rim, and `shine` sweeps a glint across. Left to right: a ball under a
light going round, a beveled button, a beveled heart.

```pyshader aspect="3:1"
from pyshader import *
import pyshader.stdlib.fragment.light as light
import pyshader.stdlib.fragment.sdf as sdf


def heart(p: float2) -> float:
    return sdf.sd_heart(p * 2.2 + float2(0.0, 0.55)) / 2.2


def button(p: float2) -> float:
    return sdf.sd_rounded_box(p, float2(0.32, 0.16), float4(0.08))


def bevelled(d: float, g: float2, base: float3, l: float3) -> float3:
    n = light.bevel_normal(d, g, 0.05)
    c = base * (0.25 + 0.75 * light.lambert(n, l))
    return c + float3(0.9) * light.blinn_phong(n, l, 40.0) + float3(0.3) * light.fresnel(n, 0.0, 4.0)


def main(uv: float2, time: float, resolution: float2) -> float4:
    cells = 3.0
    i = floor(uv.x * cells)
    p = float2(fract(uv.x * cells) - 0.5, (uv.y - 0.5) * cells * resolution.y / resolution.x)
    l = normalize(float3(cos(time), sin(time), 1.3))
    c = float3(0.12, 0.13, 0.16)
    e = 0.001
    if i < 0.5:
        c *= 1.0 - 0.6 * light.drop_shadow(sdf.sd_circle(p + 0.06 * l.xy, 0.25), 0.04)
        n = light.sphere_normal(p, 0.25)
        ball = float3(0.8, 0.15, 0.25) * (0.15 + 0.85 * light.lambert(n, l))
        ball += float3(1.0) * light.blinn_phong(n, l, 60.0) + float3(0.25, 0.4, 0.8) * light.fresnel(n, 0.0, 3.0)
        c = mix(c, ball, sdf.fill_smooth(sdf.sd_circle(p, 0.25), 0.003))
    elif i < 1.5:
        d = button(p)
        g = normalize(float2(button(p + float2(e, 0.0)) - d, button(p + float2(0.0, e)) - d))
        face = bevelled(d, g, float3(0.2, 0.45, 0.9), l)
        face += float3(0.5) * light.shine(p, 0.9, 1.2 * mod(time, 2.5) - 1.0, 0.08)
        c *= 1.0 - 0.5 * light.drop_shadow(button(p + float2(0.0, 0.04)), 0.03)
        c = mix(c, face, sdf.fill_smooth(d, 0.003))
    else:
        d = heart(p)
        g = normalize(float2(heart(p + float2(e, 0.0)) - d, heart(p + float2(0.0, e)) - d))
        c *= 1.0 - 0.5 * light.drop_shadow(heart(p + float2(0.0, 0.04)), 0.03)
        c = mix(c, bevelled(d, g, float3(0.85, 0.1, 0.3), l), sdf.fill_smooth(d, 0.003))
    return float4(light.tonemap_reinhard(c * 1.4), 1.0)
```

## Shadows

`box_shadow` is a rounded box's shadow, blurred exactly as a Gaussian blur
would; `drop_shadow` gives the same for any shape from its distance (exact
along straight edges). Place the shape where its shadow falls, draw the
shadow, then the shape. `circle_shadow` is how much of a round light a point
sees past a disk: a penumbra that widens away from the disk. Left to right:
a card lifting off the page, a star's shadow, two disks under a moving light.

```pyshader aspect="3:1"
from pyshader import *
import pyshader.stdlib.fragment.light as light
import pyshader.stdlib.fragment.sdf as sdf


def main(uv: float2, time: float, resolution: float2) -> float4:
    cells = 3.0
    i = floor(uv.x * cells)
    p = float2(fract(uv.x * cells) - 0.5, (uv.y - 0.5) * cells * resolution.y / resolution.x)
    lift = 0.5 + 0.5 * sin(time)
    c = float3(0.9, 0.9, 0.88)
    if i < 0.5:
        offset = float2(0.0, -0.01 - 0.04 * lift)
        c *= 1.0 - 0.45 * light.box_shadow(p - offset, float2(0.3, 0.2), 0.04, 0.01 + 0.04 * lift)
        card = sdf.sd_rounded_box(p, float2(0.3, 0.2), float4(0.04))
        c = mix(c, float3(1.0), sdf.fill_smooth(card, 0.002))
    elif i < 1.5:
        star = sdf.sd_star(p - float2(0.04, -0.05) * lift, 0.3, 5, 2.3)
        c *= 1.0 - 0.5 * light.drop_shadow(star, 0.01 + 0.03 * lift)
        c = mix(c, float3(1.0, 0.75, 0.2), sdf.fill_smooth(sdf.sd_star(p, 0.3, 5, 2.3), 0.002))
    else:
        lamp = float2(0.3 * cos(0.7 * time), 0.3 + 0.08 * sin(1.3 * time))
        a = float2(-0.12, 0.0)
        b = float2(0.15, -0.12)
        seen = light.circle_shadow(p, lamp, 0.05, a, 0.07) * light.circle_shadow(p, lamp, 0.05, b, 0.05)
        c = float3(0.05) + float3(1.0, 0.85, 0.6) * light.falloff_inverse_square(length(p - lamp), 0.25) * seen
        disks = sdf.op_union(sdf.sd_circle(p - a, 0.07), sdf.sd_circle(p - b, 0.05))
        c = mix(c, float3(0.15, 0.17, 0.2), sdf.fill_smooth(disks, 0.002))
        c += float3(1.0, 0.9, 0.7) * light.glow(sdf.sd_circle(p - lamp, 0.05), 0.01)
        c = light.tonemap_reinhard(c * 1.5)        # light added up: tone mapped
    return float4(c, 1.0)
```

## Soft shadows from any scene

For a scene of many shapes, march from each pixel toward the light through
the scene's own distance function: `soft_shadow_step` keeps the narrowest
the way got, as a fraction of how far along it was. The march is yours to
write, since the scene is yours; it is a few lines. `occlusion` darkens the
ground near every shape, and `falloff_range` keeps each light local.

```pyshader height="340"
from pyshader import *
import pyshader.stdlib.fragment.light as light
import pyshader.stdlib.fragment.sdf as sdf
from pyshader.stdlib.fragment.coords import centered


def scene(p: float2, time: float) -> float:
    d = sdf.sd_rounded_box(p - float2(-0.6, -0.1), float2(0.12, 0.25), float4(0.03))
    d = sdf.op_union(d, sdf.sd_circle(p - float2(0.0, 0.2 * sin(time)), 0.12))
    d = sdf.op_union(d, sdf.sd_star(p - float2(0.55, -0.15), 0.18, 5, 2.5))
    return sdf.op_union(d, sdf.sd_ring(p - float2(0.3, 0.35), float2(0.0, 1.0), 0.12, 0.04))


def shadow(p: float2, lamp: float2, time: float) -> float:
    to_lamp = lamp - p
    far = length(to_lamp)
    direction = to_lamp / far
    s = 1.0
    t = 0.01
    for _ in range(40):
        if t < far:
            d = scene(p + direction * t, time)
            s = light.soft_shadow_step(s, d, t, 12.0)
            t += max(d, 0.005)
    return clamp(s, 0.0, 1.0)


def lamp_light(p: float2, lamp: float2, tint: float3, time: float) -> float3:
    return tint * light.falloff_range(length(p - lamp), 1.6) * shadow(p, lamp, time)


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = centered(uv, resolution)
    d = scene(p, time)
    lamp_a = float2(0.9 * sin(0.5 * time), 0.75)
    lamp_b = float2(-1.2, -0.7 + 0.3 * sin(0.8 * time))
    c = float3(0.04) + lamp_light(p, lamp_a, float3(1.0, 0.8, 0.55), time)
    c += lamp_light(p, lamp_b, float3(0.35, 0.55, 1.0), time)
    c *= light.occlusion(d, 0.12, 0.6)
    c = mix(c, float3(0.85, 0.35, 0.15), sdf.fill_smooth(d, 0.003))
    c += float3(1.0, 0.85, 0.6) * light.glow(length(p - lamp_a) - 0.03, 0.01)
    c += float3(0.4, 0.6, 1.0) * light.glow(length(p - lamp_b) - 0.03, 0.01)
    return float4(light.tonemap_aces(c * 1.3), 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.light"
```
