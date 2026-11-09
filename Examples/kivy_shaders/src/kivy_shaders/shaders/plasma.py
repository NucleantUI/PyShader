"""Fragment target: Kivy's default vertex shader feeds `uv` and `color`."""

from pyshader import *

from palette import cosine


def main(uv: float2, color: float4, time: float) -> float4:
    p = uv * 6.0
    v = sin(p.x + time) + sin((p.y + time) * 0.5) + sin((p.x + p.y + time) * 0.5)
    c = p - 3.0 + float2(sin(time / 5.0), cos(time / 3.0)) * 3.0
    v += sin(sqrt(dot(c, c) + 1.0) + time)
    return float4(cosine(v * 0.25), 1.0) * color
