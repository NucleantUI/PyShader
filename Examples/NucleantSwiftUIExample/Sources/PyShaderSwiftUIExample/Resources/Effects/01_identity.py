"""Identity

layer(uv), pixel for pixel — the check that text, corners and alpha survive the round trip.
"""
from pyshader import *


def main(uv: float2) -> float4:
    return layer(uv)
