"""CRT

Barrel curvature, scanlines and a vignette. Static — no clock, no pointer.
"""
from pyshader import *

PI = 3.14159265


def main(uv: float2, resolution: float2) -> float4:
    p = uv * 2.0 - 1.0
    p *= 1.0 + 0.08 * dot(p, p)
    curved = p * 0.5 + 0.5
    inside = step(0.0, curved.x) * step(curved.x, 1.0) * step(0.0, curved.y) * step(curved.y, 1.0)

    c = layer(curved)
    line = 0.85 + 0.15 * sin(curved.y * resolution.y * PI)
    vignette = 1.0 - 0.35 * dot(p * 0.8, p * 0.8)
    c.rgb *= line * vignette
    return float4(c.rgb, c.a * inside)
