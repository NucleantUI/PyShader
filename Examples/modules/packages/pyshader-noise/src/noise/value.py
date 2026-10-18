"""Value noise: hashed lattice corners, blended with a smoothstep curve."""
from pyshader import *
from .hash import hash21


def value_noise(p: float2) -> float:
    i = floor(p)
    f = fract(p)
    u = f * f * (3.0 - 2.0 * f)
    a = hash21(i)
    b = hash21(i + float2(1.0, 0.0))
    c = hash21(i + float2(0.0, 1.0))
    d = hash21(i + float2(1.0, 1.0))
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y)
