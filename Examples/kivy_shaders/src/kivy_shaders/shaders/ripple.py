"""Compute target with content: rings run out from the pointer and bend the
image under the shader, which layer() reads. `strength` is a shader argument,
a uniform the app sets."""

from pyshader import *


def main(uv: float2, resolution: float2, mouse: float2, time: float, strength: float) -> float4:
    aspect = resolution.x / resolution.y
    p = (uv - mouse / resolution) * float2(aspect, 1.0)
    d = length(p)
    ring = sin(d * 40.0 - time * 6.0) * strength * smoothstep(0.5, 0.0, d)
    direction = p / d if d > 0.0 else float2(0.0)
    color = layer(uv + direction * float2(1.0 / aspect, 1.0) * ring)
    return color + float4(float3(ring * 4.0), 0.0)
