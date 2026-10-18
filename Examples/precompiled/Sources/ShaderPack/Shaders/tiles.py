"""A grid of shapes morphing between a circle and a box."""
from pyshader import *
import shapes

GRID = 6.0


def main(uv: float2, time: float) -> float4:
    cell = fract(uv * GRID) - 0.5
    index = floor(uv * GRID)
    t = 0.5 + 0.5 * sin(time + (index.x + index.y) * 0.6)
    d = mix(shapes.circle(cell, 0.35), shapes.box(cell, float2(0.3)), t)
    edge = 1.0 - smoothstep(0.0, 0.02, d)
    return float4(float3(0.2, 0.5, 0.9) * edge, 1.0)
