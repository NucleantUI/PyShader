"""A star, by its angle around the center."""
from pyshader import *
from .polar import angle_of


def star(p: float2, points: float, r: float, depth: float) -> float:
    """About the distance to a star of radius r, its points cut in by depth (0..1)."""
    k = 0.5 + 0.5 * cos(angle_of(p) * points)
    return length(p) - r * (1.0 - depth * (1.0 - k))
