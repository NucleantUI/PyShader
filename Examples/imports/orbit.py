"""A star orbiting a ring at dusk: three local modules, imported three ways."""
from pyshader import *
import palette                      # palette.ramp(...), palette.GOLD
from lighting import glow, halo     # glow(...), halo(...)
from shapes import *                # star, ring: the package's __all__


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = (uv - 0.5) * float2(resolution.x / resolution.y, 1.0)
    sky = palette.ramp(uv.y * 0.9 + 0.1 * sin(time * 0.3))
    orbit = float2(cos(time), sin(time)) * 0.28
    s = star(p - orbit, 5.0, 0.07, 0.5)
    r = ring(p, 0.28, 0.002)
    color = sky + palette.GOLD * (glow(s, 0.01) + 0.6 * halo(s, 0.05)) + palette.DUSK * glow(r, 0.004)
    return float4(color, 1.0)
