"""Ripple

Rings spreading from the centre, displacing what they pass over.
"""
from pyshader import *


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = uv - 0.5
    p.x *= resolution.x / resolution.y
    d = length(p)
    ring = sin(d * 40.0 - time * 5.0) * 0.006 * smoothstep(0.6, 0.0, d)
    direction = p / d if d > 0.0 else float2(0.0)
    direction.x *= resolution.y / resolution.x
    return layer(uv + direction * ring)
