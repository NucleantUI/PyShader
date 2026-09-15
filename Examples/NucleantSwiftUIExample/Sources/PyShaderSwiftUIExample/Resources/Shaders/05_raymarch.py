"""Raymarch

A signed-distance sphere on a plane, marched in a loop with normals from a helper.
"""
from pyshader import *

MAX_STEPS = 64


def scene(p: float3, time: float) -> float:
    sphere = length(p - float3(0.0, 1.0 + 0.3 * sin(time * 2.0), 0.0)) - 1.0
    plane = p.y
    return min(sphere, plane)


def normal(p: float3, time: float) -> float3:
    e = 0.001
    dx = scene(p + float3(e, 0.0, 0.0), time) - scene(p - float3(e, 0.0, 0.0), time)
    dy = scene(p + float3(0.0, e, 0.0), time) - scene(p - float3(0.0, e, 0.0), time)
    dz = scene(p + float3(0.0, 0.0, e), time) - scene(p - float3(0.0, 0.0, e), time)
    return normalize(float3(dx, dy, dz))


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = uv * 2.0 - 1.0
    p.x *= resolution.x / resolution.y
    ro = float3(0.0, 1.5, -4.0)
    rd = normalize(float3(p, 1.6))

    t = 0.0
    hit = False
    for i in range(MAX_STEPS):
        d = scene(ro + rd * t, time)
        if d < 0.001:
            hit = True
            break
        t += d
        if t > 20.0:
            break

    sky = float3(0.55, 0.7, 0.9) - float3(0.3) * p.y
    if not hit:
        return float4(sky, 1.0)

    pos = ro + rd * t
    n = normal(pos, time)
    light = normalize(float3(0.6, 0.8, -0.5))
    diffuse = max(dot(n, light), 0.0)
    base = float3(0.9, 0.4, 0.3) if pos.y > 0.01 else float3(0.6)
    col = base * (0.15 + 0.85 * diffuse)
    col = mix(col, sky, 1.0 - exp(-0.03 * t * t))
    return float4(col, 1.0)
