"""Drifting clouds: fBm from the installed `noise` library, coloured by the
local `palettes` module. Only what is used ends up in the SPIR-V."""
from pyshader import *
from noise import fbm
import palettes

DRIFT = float2(0.05, 0.02)


def main(uv: float2, time: float) -> float4:
    p = uv * 3.0 + DRIFT * time * 10.0
    # Domain warp: fBm of fBm.
    q = float2(fbm(p), fbm(p + float2(5.2, 1.3)))
    density = fbm(p + 4.0 * q)
    sky = palettes.shade(palettes.OCEAN, uv.y * 0.5)
    cloud = palettes.shade(palettes.SUNSET, density + 0.3 * time)
    return float4(mix(sky, cloud, smoothstep(0.35, 0.75, density)), 1.0)
