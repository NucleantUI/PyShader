"""Cyber Fuji 2020

https://www.shadertoy.com/view/Wt33Wf — Jan Mróz (jaszunio15), CC BY 3.0.
Port of opengl/cyber-fuji-2020.glsl. Helpers that read iTime take `time`.
"""
from pyshader import *


def sun(uv: float2, battery: float, time: float) -> float:
    val = smoothstep(0.3, 0.29, length(uv))
    bloom = smoothstep(0.7, 0.0, length(uv))
    cut = 3.0 * sin((uv.y + time * 0.2 * (battery + 0.02)) * 100.0) + clamp(uv.y * 14.0 + 1.0, -6.0, 6.0)
    cut = clamp(cut, 0.0, 1.0)
    return clamp(val * cut, 0.0, 1.0) + bloom * 0.6


def grid(uv: float2, battery: float, time: float) -> float:
    size = float2(uv.y, uv.y * uv.y * 0.2) * 0.01
    uv += float2(0.0, time * 4.0 * (battery + 0.05))
    uv = abs(fract(uv) - 0.5)
    lines = smoothstep(size, float2(0.0), uv)
    lines += smoothstep(size * 5.0, float2(0.0), uv) * 0.4 * battery
    return clamp(lines.x + lines.y, 0.0, 3.0)


def dot2(v: float2) -> float:
    return dot(v, v)


def sdTrapezoid(p: float2, r1: float, r2: float, he: float) -> float:
    k1 = float2(r2, he)
    k2 = float2(r2 - r1, 2.0 * he)
    p.x = abs(p.x)
    ca = float2(p.x - min(p.x, r1 if p.y < 0.0 else r2), abs(p.y) - he)
    cb = p - k1 + k2 * clamp(dot(k1 - p, k2) / dot2(k2), 0.0, 1.0)
    s = -1.0 if cb.x < 0.0 and ca.y < 0.0 else 1.0
    return s * sqrt(min(dot2(ca), dot2(cb)))


def sdLine(p: float2, a: float2, b: float2) -> float:
    pa = p - a
    ba = b - a
    h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0)
    return length(pa - ba * h)


def sdBox(p: float2, b: float2) -> float:
    d = abs(p) - b
    return length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0)


def opSmoothUnion(d1: float, d2: float, k: float) -> float:
    h = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0)
    return mix(d2, d1, h) - k * h * (1.0 - h)


def sdCloud(p: float2, a1: float2, b1: float2, a2: float2, b2: float2, w: float) -> float:
    lineVal1 = sdLine(p, a1, b1)
    lineVal2 = sdLine(p, a2, b2)
    ww = float2(w * 1.5, 0.0)
    left = max(a1 + ww, a2 + ww)
    right = min(b1 - ww, b2 - ww)
    boxCenter = (left + right) * 0.5
    boxH = abs(a2.y - a1.y) * 0.5
    boxVal = sdBox(p - boxCenter, float2(0.04, boxH)) + w

    uniVal1 = opSmoothUnion(lineVal1, boxVal, 0.05)
    uniVal2 = opSmoothUnion(lineVal2, boxVal, 0.05)
    return min(uniVal1, uniVal2)


def main(frag_coord: float2, resolution: float2, time: float) -> float4:
    uv = (2.0 * frag_coord - resolution) / resolution.y
    battery = 1.0

    # Grid
    fog = smoothstep(0.1, -0.02, abs(uv.y + 0.2))
    col = float3(0.0, 0.1, 0.2)
    if uv.y < -0.2:
        uv.y = 3.0 / (abs(uv.y + 0.2) + 0.05)
        uv.x *= uv.y * 1.0
        gridVal = grid(uv, battery, time)
        col = mix(col, float3(1.0, 0.5, 1.0), gridVal)
    else:
        fujiD = min(uv.y * 4.5 - 0.5, 1.0)
        uv.y -= battery * 1.1 - 0.51

        sunUV = uv
        fujiUV = uv

        # Sun
        sunUV += float2(0.75, 0.2)
        col = float3(1.0, 0.2, 1.0)
        sunVal = sun(sunUV, battery, time)

        col = mix(col, float3(1.0, 0.4, 0.1), sunUV.y * 2.0 + 0.2)
        col = mix(float3(0.0, 0.0, 0.0), col, sunVal)

        # fuji
        fujiVal = sdTrapezoid(uv + float2(-0.75 + sunUV.y * 0.0, 0.5), 1.75 + pow(uv.y * uv.y, 2.1), 0.2, 0.5)
        waveVal = uv.y + sin(uv.x * 20.0 + time * 2.0) * 0.05 + 0.2
        wave_width = smoothstep(0.0, 0.01, waveVal)

        # fuji color
        col = mix(col, mix(float3(0.0, 0.0, 0.25), float3(1.0, 0.0, 0.5), fujiD), step(fujiVal, 0.0))
        # fuji top snow
        col = mix(col, float3(1.0, 0.5, 1.0), wave_width * step(fujiVal, 0.0))
        # fuji outline
        col = mix(col, float3(1.0, 0.5, 1.0), 1.0 - smoothstep(0.0, 0.01, abs(fujiVal)))

        # horizon color
        col += mix(col, mix(float3(1.0, 0.12, 0.8), float3(0.0, 0.0, 0.2), clamp(uv.y * 3.5 + 3.0, 0.0, 1.0)), step(0.0, fujiVal))

        # cloud
        cloudUV = uv
        cloudUV.x = mod(cloudUV.x + time * 0.1, 4.0) - 2.0
        cloudTime = time * 0.5
        cloudY = -0.5
        cloudVal1 = sdCloud(cloudUV,
                            float2(0.1 + sin(cloudTime + 140.5) * 0.1, cloudY),
                            float2(1.05 + cos(cloudTime * 0.9 - 36.56) * 0.1, cloudY),
                            float2(0.2 + cos(cloudTime * 0.867 + 387.165) * 0.1, 0.25 + cloudY),
                            float2(0.5 + cos(cloudTime * 0.9675 - 15.162) * 0.09, 0.25 + cloudY), 0.075)
        cloudY = -0.6
        cloudVal2 = sdCloud(cloudUV,
                            float2(-0.9 + cos(cloudTime * 1.02 + 541.75) * 0.1, cloudY),
                            float2(-0.5 + sin(cloudTime * 0.9 - 316.56) * 0.1, cloudY),
                            float2(-1.5 + cos(cloudTime * 0.867 + 37.165) * 0.1, 0.25 + cloudY),
                            float2(-0.6 + sin(cloudTime * 0.9675 + 665.162) * 0.09, 0.25 + cloudY), 0.075)

        cloudVal = min(cloudVal1, cloudVal2)

        col = mix(col, float3(0.0, 0.0, 0.2), 1.0 - smoothstep(0.075 - 0.0001, 0.075, cloudVal))
        col += float3(1.0, 1.0, 1.0) * (1.0 - smoothstep(0.0, 0.01, abs(cloudVal - 0.075)))

    col += fog * fog * fog
    col = mix(float3(col.r, col.r, col.r) * 0.5, col, battery * 0.7)

    return float4(col, 1.0)
