"""Rings

while-loop accumulation with break/continue, centred on the pointer once it has moved.
"""
from pyshader import *


def main(uv: float2, time: float, mouse: float2, resolution: float2) -> float4:
    centre = mouse / resolution if mouse.x > 0.0 and mouse.y > 0.0 else float2(0.5)
    p = uv - centre
    p.x *= resolution.x / resolution.y
    d = length(p)

    acc = 0.0
    i = 0
    while i < 12:
        i += 1
        if i % 4 == 0:
            continue
        if d * float(i) > 8.0:
            break
        acc += sin(d * 30.0 * float(i) * 0.25 - time * 2.0 + float(i)) / float(i)

    glow = smoothstep(0.5, 0.0, d)
    col = float3(0.1, 0.2, 0.4) + float3(0.9, 0.5, 0.2) * (acc * 0.5 + 0.5) * glow
    return float4(col, 1.0)
