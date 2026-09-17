"""Liquid glass (squircle)

github.com/OverShifted/LiquidGlass (MIT) as a NucleantSwiftUI effect: a
superellipse pad that magnifies the backdrop toward its centre, blurs and
grains it a little, and lights the rim with an angular glow. A different
recipe from liquid-glass.py: no surface normal, the displacement is a
function of the distance to the edge alone.

Arguments: `power` (superellipse exponent, 2 = ellipse, 4+ = squircle),
`blur` (px) and `noise` (grain strength).
"""
from pyshader import *

E = 2.718281828459045


def sd_superellipse(p: float2, n: float, r: float) -> float:
    a = abs(p)
    numerator = pow(a.x, n) + pow(a.y, n) - pow(r, n)
    denominator = n * sqrt(pow(a.x, 2.0 * n - 2.0) + pow(a.y, 2.0 * n - 2.0)) + 0.00001
    return numerator / denominator


def squeeze(x: float) -> float:
    # 1 at the centre, falling towards the rim: how far a sample is pulled in.
    return 1.0 - 2.3 * pow(5.2 * E, -6.9 * x - 0.7)


def rand(co: float2) -> float:
    return fract(sin(dot(co, float2(12.9898, 78.233))) * 43758.5453)


def blur5(uv: float2, texel: float2, direction: float2) -> float4:
    off = direction * 1.3333333333 * texel
    return (layer(uv) * 0.2941176471
            + layer(uv + off) * 0.3529411765
            + layer(uv - off) * 0.3529411765)


def main(uv: float2, frag_coord: float2, resolution: float2, power: float, blur: float, noise: float) -> float4:
    p = (uv - 0.5) * 2.0
    d = sd_superellipse(p, power, 1.0)
    dist = max(-d, 0.0)

    sample_p = p * pow(squeeze(dist), 3.0)
    coord = sample_p * 0.5 + 0.5
    texel = blur / resolution
    color = (blur5(coord, texel, float2(1.0, 0.0)) + blur5(coord, texel, float2(0.0, 1.0))) * 0.5

    grain = rand(frag_coord * 0.001) - 0.5
    glow = sin(atan2(p.y, p.x) - 0.5)
    mul = glow * 0.3 * smoothstep(0.06, 0.0, dist) + 1.0
    rgb = (color.rgb + grain * noise) * mul

    # One pixel of anti-aliasing at the rim, in the pad's [-1, 1] units.
    aa = 2.0 / min(resolution.x, resolution.y)
    return float4(clamp(rgb, 0.0, 1.0), 1.0 - smoothstep(-aa, 0.0, d))
