"""Wave

A moving sine distortion of the sample position.
"""
from pyshader import *


def main(uv: float2, time: float) -> float4:
    dx = sin(uv.y * 30.0 + time * 3.0) * 0.012
    dy = cos(uv.x * 20.0 + time * 2.0) * 0.006
    return layer(uv + float2(dx, dy))
