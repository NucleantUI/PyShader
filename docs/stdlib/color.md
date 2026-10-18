# Color & blend

Color spaces, palettes, and the blend modes of image editors.

```py
from pyshader.stdlib.fragment.color import hsb_to_rgb, palette
from pyshader.stdlib.fragment import blend         # blend.screen(base, top)
```

## Color spaces

A color wheel in HSB, `hsb_to_rgb(float3(hue, saturation, brightness))`:
the angle is the hue, the distance from the center the saturation. Around it,
the wheel's colors pass through `rgb_to_hsb` and back with their hue turned
by `hue_shift`, and the outer ring goes through `desaturate`.

```pyshader height="320"
from pyshader import *
from pyshader.stdlib.fragment.color import hsb_to_rgb, hue_shift, desaturate
from pyshader.stdlib.fragment.coords import centered, to_polar


def main(uv: float2, time: float, resolution: float2) -> float4:
    polar = to_polar(centered(uv, resolution))
    r = polar.x
    hue = polar.y / 6.28318530718 + 0.5
    color = float3(0.08)
    if r < 0.55:
        color = hsb_to_rgb(float3(hue + time * 0.05, r / 0.55, 1.0))
    elif r < 0.7:
        color = hue_shift(hsb_to_rgb(float3(hue, 1.0, 1.0)), time * 0.2)
    elif r < 0.85:
        color = desaturate(hsb_to_rgb(float3(hue, 1.0, 1.0)), 0.5 + 0.5 * sin(time))
    return float4(color, 1.0)
```

## Palettes

Inigo Quilez's cosine palettes: `palette(t, a, b, c, d)` is
`a + b·cos(2π(c·t + d))`, a whole gradient in four colors. Each band is one
set of them; `rainbow(t)` is the first.

```pyshader height="300"
from pyshader import *
from pyshader.stdlib.fragment.color import palette, rainbow


def band(i: float, t: float) -> float3:
    if i < 0.5:
        return rainbow(t)
    if i < 1.5:
        return palette(t, float3(0.5), float3(0.5), float3(1.0, 1.0, 0.5), float3(0.8, 0.9, 0.3))
    if i < 2.5:
        return palette(t, float3(0.5), float3(0.5), float3(1.0, 0.7, 0.4), float3(0.0, 0.15, 0.2))
    if i < 3.5:
        return palette(t, float3(0.5), float3(0.5), float3(2.0, 1.0, 0.0), float3(0.5, 0.2, 0.25))
    return palette(t, float3(0.8, 0.5, 0.4), float3(0.2, 0.4, 0.2), float3(2.0, 1.0, 1.0), float3(0.0, 0.25, 0.25))


def main(uv: float2, time: float) -> float4:
    i = floor((1.0 - uv.y) * 5.0)
    color = band(i, uv.x + time * 0.1)
    color *= 0.85 + 0.15 * step(0.02, fract((1.0 - uv.y) * 5.0))
    return float4(color, 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.color"
```

## Blend modes

The same two layers, a gradient below and moving rings above, combined by
twelve blend modes. Left to right, top to bottom: `multiply`, `screen`,
`overlay`, `darken`, `lighten`, `color_dodge`, `color_burn`, `hard_light`,
`soft_light`, `difference`, `exclusion` and `add`.

```pyshader height="300"
from pyshader import *
import pyshader.stdlib.fragment.blend as blend
from pyshader.stdlib.fragment.color import rainbow
from pyshader.stdlib.fragment.pattern import tile, tile_index


def combine(i: float, base: float3, top: float3) -> float3:
    if i < 0.5:
        return blend.multiply(base, top)
    if i < 1.5:
        return blend.screen(base, top)
    if i < 2.5:
        return blend.overlay(base, top)
    if i < 3.5:
        return blend.darken(base, top)
    if i < 4.5:
        return blend.lighten(base, top)
    if i < 5.5:
        return blend.color_dodge(base, top)
    if i < 6.5:
        return blend.color_burn(base, top)
    if i < 7.5:
        return blend.hard_light(base, top)
    if i < 8.5:
        return blend.soft_light(base, top)
    if i < 9.5:
        return blend.difference(base, top)
    if i < 10.5:
        return blend.exclusion(base, top)
    return blend.add(base, top)


def main(uv: float2, time: float) -> float4:
    grid = float2(4.0, 3.0)
    st = fract(uv * grid)
    cell = floor(uv * grid)
    i = cell.x + (2.0 - cell.y) * 4.0
    base = mix(float3(0.1, 0.2, 0.5), float3(1.0, 0.85, 0.6), st.y)
    rings = 0.5 + 0.5 * sin(length(st - 0.5) * 30.0 - time * 3.0)
    top = rainbow(st.x + time * 0.1) * rings
    color = combine(i, base, top)
    edge = step(0.015, st.x) * step(0.015, st.y)
    return float4(color * edge, 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.blend"
```
