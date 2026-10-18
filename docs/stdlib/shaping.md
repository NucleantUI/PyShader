# Shaping & easing

Curves that take a value in 0..1 and bend it: for drawing lines and
gradients that are not straight, for falloffs and pulses, and for animation.

```py
from pyshader.stdlib.fragment.shaping import gain, cubic_pulse, plot
from pyshader.stdlib.fragment import easing        # easing.bounce_out(t)
```

## Shaping functions

Nine of them, one per cell, each drawn as `y = f(x)` with `plot`. From the
top left: `almost_unit_identity`, `exp_impulse`, `cubic_pulse`, `gain`,
`parabola`, `pcurve`, `double_cubic_seat`, `logistic_sigmoid` and
`quadratic_bezier`. Their parameters move with time.

```pyshader height="360"
from pyshader import *
from pyshader.stdlib.fragment.shaping import *
from pyshader.stdlib.fragment.pattern import tile, tile_index


def curve(i: float, x: float, k: float) -> float:
    if i < 0.5:
        return almost_unit_identity(x)
    if i < 1.5:
        return exp_impulse(x, 4.0 + 8.0 * k)
    if i < 2.5:
        return cubic_pulse(0.5, 0.1 + 0.2 * k, x)
    if i < 3.5:
        return gain(x, 0.3 + 3.0 * k)
    if i < 4.5:
        return parabola(x, 0.5 + 2.0 * k)
    if i < 5.5:
        return pcurve(x, 1.0 + 2.0 * k, 2.0)
    if i < 6.5:
        return double_cubic_seat(x, 0.3 + 0.4 * k, 0.5)
    if i < 7.5:
        return logistic_sigmoid(x, 0.5 + 0.45 * k)
    return quadratic_bezier(x, 0.1 + 0.8 * k, 0.9 - 0.8 * k)


def main(uv: float2, time: float) -> float4:
    st = tile(uv, 3.0)
    cell = tile_index(uv, 3.0)
    i = cell.x + (2.0 - cell.y) * 3.0
    k = 0.5 + 0.5 * sin(time * 0.8)
    y = curve(i, st.x, k)
    shade = 0.08 + 0.04 * mod(cell.x + cell.y, 2.0)
    color = float3(shade) + float3(0.15, 0.2, 0.3) * step(st.y, y)
    color = mix(color, float3(1.0, 0.8, 0.3), plot(st, y))
    return float4(color, 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.shaping"
```

## Easing

Each row moves a dot from left to right with a different easing, from top to
bottom: `linear`, `sine_in_out`, `quad_in_out`, `cubic_in_out`,
`expo_in_out`, `circ_in_out`, `back_in_out`, `elastic_out` and
`bounce_out`. The faint line is where `linear` would be.

```pyshader height="360"
from pyshader import *
import pyshader.stdlib.fragment.easing as easing


def ease(i: float, t: float) -> float:
    if i < 0.5:
        return easing.linear(t)
    if i < 1.5:
        return easing.sine_in_out(t)
    if i < 2.5:
        return easing.quad_in_out(t)
    if i < 3.5:
        return easing.cubic_in_out(t)
    if i < 4.5:
        return easing.expo_in_out(t)
    if i < 5.5:
        return easing.circ_in_out(t)
    if i < 6.5:
        return easing.back_in_out(t)
    if i < 7.5:
        return easing.elastic_out(t)
    return easing.bounce_out(t)


def main(uv: float2, time: float, resolution: float2) -> float4:
    rows = 9.0
    row = floor((1.0 - uv.y) * rows)
    y = 1.0 - (row + 0.5) / rows
    t = clamp(mod(time * 0.5, 1.4), 0.0, 1.0)
    x = mix(0.08, 0.92, ease(row, t))
    aspect = resolution.x / resolution.y
    d = length((uv - float2(x, y)) * float2(aspect, 1.0))
    color = float3(0.07, 0.07, 0.1) + float3(0.03) * mod(row, 2.0)
    color += float3(0.25) * (1.0 - smoothstep(0.0, 0.004, abs(uv.x - mix(0.08, 0.92, t)))) * step(abs(uv.y - y), 0.5 / rows)
    color = mix(color, float3(0.4, 0.8, 1.0), 1.0 - smoothstep(0.025, 0.03, d))
    return float4(color, 1.0)
```

```pyshader-api module="pyshader.stdlib.fragment.easing"
```
