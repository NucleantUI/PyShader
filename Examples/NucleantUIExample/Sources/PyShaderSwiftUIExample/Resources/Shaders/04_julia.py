"""Julia set

A for-range escape-time loop; the constant orbits with time.
"""
from pyshader import *

ITERATIONS = 64


def main(uv: float2, time: float, resolution: float2) -> float4:
    z = (uv * 2.0 - 1.0) * 1.4
    z.x *= resolution.x / resolution.y
    c = float2(0.7885 * cos(time * 0.3), 0.7885 * sin(time * 0.3))

    n = 0
    for i in range(ITERATIONS):
        z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c
        if dot(z, z) > 4.0:
            break
        n += 1

    if n == ITERATIONS:
        return float4(0.0, 0.0, 0.0, 1.0)
    t = float(n) / float(ITERATIONS)
    col = 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)))
    return float4(col, 1.0)
