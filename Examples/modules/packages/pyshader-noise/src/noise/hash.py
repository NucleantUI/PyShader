"""Integer-free hashes: a float2 in, pseudo-random values in [0, 1) out."""
from pyshader import *


def hash21(p: float2) -> float:
    p = fract(p * float2(123.34, 456.21))
    p += dot(p, p + 45.32)
    return fract(p.x * p.y)


def hash22(p: float2) -> float2:
    return float2(hash21(p), hash21(p + 17.17))
