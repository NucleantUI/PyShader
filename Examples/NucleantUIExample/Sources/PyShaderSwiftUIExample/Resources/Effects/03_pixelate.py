"""Pixelate

4-pixel cells: every pixel in a cell reads the cell's centre. Static — dispatched once.
"""
from pyshader import *


def main(uv: float2, resolution: float2) -> float4:
    cells = resolution / 4.0
    cell = (floor(uv * cells) + 0.5) / cells
    return layer(cell)
