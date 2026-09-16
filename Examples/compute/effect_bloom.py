"""Bloom as a `.shader(_:)` effect: threshold the bright pixels of layer(),
gaussian-blur them with a tap loop, then add the glow under/around the
original - additive, so it also shows on top of an opaque background."""
from pyshader import *


THRESHOLD = 0.45   # brightness where glow starts
SOFT_KNEE = 0.20   # soft edge around the threshold
INTENSITY = 0.9    # glow strength
RADIUS = 6         # blur taps per axis (13x13 kernel)
SPREAD = 2.5       # texel step between taps -> glow size


def bright(s: float4) -> float3:
    c = s.rgb * s.a
    # max channel, not luminance: saturated red/blue blocks glow too
    b = max(c.r, max(c.g, c.b))
    return c * smoothstep(THRESHOLD - SOFT_KNEE, THRESHOLD + SOFT_KNEE, b)


def main(uv: float2, resolution: float2) -> float4:
    color = layer(uv)
    texel = SPREAD / resolution

    bloom = float3(0.0)
    total = 0.0
    sigma2 = float(RADIUS * RADIUS) * 0.5
    for x in range(-RADIUS, RADIUS + 1):
        for y in range(-RADIUS, RADIUS + 1):
            off = float2(float(x), float(y))
            w = exp(-dot(off, off) / sigma2)
            bloom += bright(layer(uv + off * texel)) * w
            total += w
    bloom = (bloom / total) * INTENSITY

    # Additive glow: displayed result is original + bloom, both over the
    # opaque board and out into transparent surroundings (alpha is raised
    # to the glow so the halo survives straight-alpha blending).
    glow = clamp(max(bloom.r, max(bloom.g, bloom.b)), 0.0, 1.0)
    a = max(color.a, glow)
    rgb = (color.rgb * color.a + bloom) / max(a, 1e-4)
    return float4(rgb, a)
