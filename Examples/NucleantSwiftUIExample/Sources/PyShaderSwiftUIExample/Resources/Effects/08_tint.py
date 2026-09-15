"""Tint (arguments)

`tint` and `strength` arrive as ShaderArguments from Swift, by name.
"""
from pyshader import *


def main(uv: float2, tint: float4, strength: float) -> float4:
    c = layer(uv)
    return float4(mix(c.rgb, tint.rgb, strength * c.a), c.a)
