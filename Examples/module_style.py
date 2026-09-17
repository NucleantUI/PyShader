"""Optional import of the stub module (ignored by the compiler), module.attr calls, chained compare."""
from pyshader import *
import pyshader

RED: float3 = float3(1.0, 0.0, 0.0)
HALF_RED = RED * 0.5


def band(x: float, lo: float, hi: float) -> float:
    return 1.0 if lo <= x < hi else 0.0


def main(uv: float2) -> float4:
    s = pyshader.sin(uv.x * 6.28)
    w = band(uv.y, 0.4, 0.6)
    c = HALF_RED + RED * w * s
    c[1] = uv[0]
    c[-1] = uv[-1]
    idx = int(uv.x * 3.0)
    return float4(c, c[idx])
