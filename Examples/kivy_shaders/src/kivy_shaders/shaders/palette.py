"""A local module: the shaders beside it import it like any Python module."""

from pyshader import *


def cosine(t: float) -> float3:
    return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)))
