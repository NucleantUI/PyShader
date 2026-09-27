"""Tunnel

Polar remap into a scrolling checker tube, darkening towards the centre.
"""
from pyshader import *

PI = 3.14159265


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = uv * 2.0 - 1.0
    p.x *= resolution.x / resolution.y
    r = length(p)
    angle = atan(p.y, p.x)
    depth = 0.3 / (r + 0.001)
    u = angle / PI * 4.0
    v = depth + time * 1.5
    checker = 1.0 if (int(floor(u)) + int(floor(v))) % 2 == 0 else 0.0
    shade = clamp(r * 2.2, 0.0, 1.0)
    tint = float3(0.9, 0.6, 0.3) * checker + float3(0.2, 0.3, 0.6) * (1.0 - checker)
    return float4(tint * shade, 1.0)
