"""Lambdas (monomorphized per argument types), tuple unpacking, half/short/int/uint math, ternaries."""

square = lambda x: x * x
add3 = lambda a, b, c: a + b + c


def hash21(p: float2) -> float:
    q = uint2(int2(p * 1000.0))
    h = q.x * 1103515245 + q.y * 12345
    h = h ^ (h >> 13)
    h = h * 2654435761
    return float(h & 0xFFFF) / 65535.0


def main(uv: float2, time: float) -> float4:
    x, y = uv
    s = square(x) + square(uv)  # float and float2 instantiations
    v = add3(x, y, 1.5)

    h: half = half(0.5)
    h2 = h * half(2.0)
    hv = half3(h, h2, half(0.25))

    sh: short = short(3)
    si = sh + 4          # promotes to int
    flag = si > 5 and not (v < 0.0)

    n = hash21(uv + time)
    base = float3(hv) if flag else float3(n)
    mixed = mix(base, float3(s.y, v * 0.1, 0.2), 0.5)

    m = 7 // 2
    q = -7 // 2           # -4, Python semantics
    r = -7 % 3            # 2, Python semantics
    fz = 7 / 2            # 3.5, true division
    e = 2 ** 3            # 8.0
    total = float(m + q + r) + fz + e

    saturated = saturate(mixed + total * 0.001)
    return float4(saturated, 1.0)
