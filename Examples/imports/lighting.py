"""Light falloffs for distance fields: d is 0 on a shape's edge."""
from pyshader import *


def glow(d: float, width: float) -> float:
    """1 on the edge, fading over about `width` either side."""
    return width / (width + abs(d))


def halo(d: float, radius: float) -> float:
    """1 inside, fading out over about `radius` outside."""
    return exp(-max(d, 0.0) / radius)
