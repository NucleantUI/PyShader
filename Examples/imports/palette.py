"""Colours for the imports tutorial: three named colours and a ramp through them."""
from pyshader import *

NIGHT = float3(0.04, 0.03, 0.10)
DUSK = float3(0.45, 0.18, 0.45)
GOLD = float3(1.0, 0.75, 0.30)


def ramp(t: float) -> float3:
    """NIGHT at 0, through DUSK, to GOLD at 1."""
    t = clamp(t, 0.0, 1.0)
    return mix(mix(NIGHT, DUSK, smoothstep(0.0, 0.5, t)), GOLD, smoothstep(0.5, 1.0, t))
