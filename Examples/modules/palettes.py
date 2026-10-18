"""Cosine palettes (Inigo Quilez): a + b * cos(2π (c t + d)).

A local module: it sits next to the shader that imports it, which is
always on the import path.
"""
from pyshader import *


class Palette:
    a: float3
    b: float3
    c: float3
    d: float3


SUNSET = Palette(float3(0.5, 0.4, 0.4), float3(0.5, 0.4, 0.3), float3(1.0, 1.0, 0.5), float3(0.8, 0.9, 0.3))
OCEAN = Palette(float3(0.2, 0.4, 0.6), float3(0.3, 0.3, 0.4), float3(1.0, 1.0, 1.0), float3(0.0, 0.1, 0.2))


def shade(p: Palette, t: float) -> float3:
    return p.a + p.b * cos(6.28318 * (p.c * t + p.d))


def unused_debug(t: float) -> float3:
    # Never called by the shader, so never compiled into it.
    return float3(t)
