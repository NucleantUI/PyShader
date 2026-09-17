"""Lambdas

Lambdas bound at module level, instantiated per argument type: `sq` runs on floats and float2s.
"""
from pyshader import *

sq = lambda x: x * x
wave = lambda p, t, k: sin(p * k + t) * 0.5 + 0.5


def main(uv: float2, time: float) -> float4:
    x, y = uv
    a = wave(x, time, 9.0)
    b = wave(y, time * 1.3, 7.0)
    c = wave(uv, time, 5.0)
    r = sq(a) + sq(c).x * 0.3
    g = sq(b) + sq(c).y * 0.3
    return float4(r, g, sq(x - 0.5) * 4.0, 1.0)
