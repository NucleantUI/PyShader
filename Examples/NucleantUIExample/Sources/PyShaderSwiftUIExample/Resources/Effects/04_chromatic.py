"""Chromatic

Red and blue pulled apart, more so the further from the pointer.
"""
from pyshader import *


def main(uv: float2, mouse: float2, resolution: float2) -> float4:
    focus = mouse / resolution if mouse.x > 0.0 and mouse.y > 0.0 else float2(0.5)
    shift = (uv - focus) * 0.03
    r = layer(uv + shift).r
    g = layer(uv)
    b = layer(uv - shift).b
    return float4(r, g.g, b, g.a)
