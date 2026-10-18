"""Polar coordinates, for the package's own modules."""
from pyshader import *


def angle_of(p: float2) -> float:
    return atan2(p.y, p.x)
