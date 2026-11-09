"""Compute target: one fragment per pixel of the widget. A `for` loop over a
constant range, as OpenGL ES 2 wants, and the pointer as a light."""

from pyshader import *

from palette import cosine

BANDS = 5


def band(p: float2, i: int, time: float) -> float:
    k = float(i)
    y = 0.45 + 0.08 * k + 0.05 * sin(p.x * (2.0 + k) + time * (0.6 + 0.2 * k))
    return 0.004 / abs(p.y - y)


def main(uv: float2, frag_coord: float2, resolution: float2, mouse: float2, time: float) -> float4:
    p = float2(uv.x * resolution.x / resolution.y, uv.y)
    glow = float3(0.0)
    for i in range(BANDS):
        glow += cosine(float(i) / BANDS + time * 0.05) * band(p, i, time)
    light = 40.0 / (length(frag_coord - mouse) + 40.0)
    sky = mix(float3(0.01, 0.02, 0.06), float3(0.05, 0.03, 0.12), uv.y)
    return float4(sky + glow + light * 0.25, 1.0)
