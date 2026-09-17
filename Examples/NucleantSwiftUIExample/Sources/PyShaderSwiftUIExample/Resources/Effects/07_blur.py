"""Blur

13-tap gaussian in one pass; weights in a float3 indexed dynamically, taps through a helper.
"""
from pyshader import *


def tap(p: float2, offset: float2, weight: float) -> float4:
    c = layer(p + offset)
    return float4(c.rgb * c.a, c.a) * weight


def main(uv: float2, resolution: float2) -> float4:
    texel = 1.5 / resolution
    acc = tap(uv, float2(0.0), 0.16)
    w = float3(0.13, 0.07, 0.03)
    for i in range(1, 4):
        d = texel * float(i)
        acc += tap(uv, float2(d.x, 0.0), w[i - 1])
        acc += tap(uv, float2(-d.x, 0.0), w[i - 1])
        acc += tap(uv, float2(0.0, d.y), w[i - 1])
        acc += tap(uv, float2(0.0, -d.y), w[i - 1])
    acc /= 0.16 + 4.0 * (0.13 + 0.07 + 0.03)
    return float4(acc.rgb / acc.a, acc.a) if acc.a > 0.0 else float4(0.0)
