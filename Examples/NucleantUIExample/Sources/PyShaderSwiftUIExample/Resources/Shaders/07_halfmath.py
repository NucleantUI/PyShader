"""Half & int types

16-bit float math, integer hashing with uint, and vector comparisons reduced with any()/all().
"""
from pyshader import *


def hash21(p: float2) -> float:
    q = uint2(int2(p * 1024.0))
    h = q.x * 1103515245 + q.y * 12345
    h = h ^ (h >> 13)
    h = h * 2654435761
    return float(h & 0xFFFF) / 65535.0


def main(uv: float2, time: float) -> float4:
    cell = floor(uv * 12.0)
    n = hash21(cell + floor(time))
    h: half2 = half2(uv)
    hv = h * half(2.0) - half(1.0)
    ring = float(length(hv))
    bright = any(abs(hv) > half(0.9)) or all(abs(hv) < half(0.1))
    base = float3(n, fract(n * 7.0), fract(n * 13.0))
    return float4(base * (1.0 - ring * 0.5) + (float3(0.4) if bright else float3(0.0)), 1.0)
