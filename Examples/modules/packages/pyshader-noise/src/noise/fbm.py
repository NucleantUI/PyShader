"""Fractal Brownian motion: octaves of value noise, each rotated and doubled."""
from pyshader import *
from .value import value_noise

OCTAVES = 5
GAIN = 0.5
# Rotates each octave so the lattice of one does not line up with the next.
ROTATION = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8))


def fbm(p: float2) -> float:
    total = 0.0
    amplitude = 0.5
    for i in range(OCTAVES):
        total += amplitude * value_noise(p)
        p = ROTATION * p * 2.0
        amplitude *= GAIN
    return total
