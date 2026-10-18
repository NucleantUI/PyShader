"""A ring around the center."""
from pyshader import *


def ring(p: float2, r: float, width: float) -> float:
    """The distance to a circle of radius r, `width` thick."""
    return abs(length(p) - r) - width
