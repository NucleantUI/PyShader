"""Signed distances, imported by tiles.py from beside it."""
from pyshader import *


def circle(p: float2, r: float) -> float:
    return length(p) - r


def box(p: float2, size: float2) -> float:
    d = abs(p) - size
    return length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0)
