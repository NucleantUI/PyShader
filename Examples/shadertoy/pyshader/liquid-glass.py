""""Optically correct" liquid glass

https://www.shadertoy.com/view/wccSDf — the pad from lq.glsl as a rounded
rect (120×40 half-size, radius 40) following the mouse over the stripes.
Port of opengl/liquid-glass.glsl: dFdx/dFdy of the SDF are forward
differences, everything else is the original's math, line for line.
"""
from pyshader import *


def sdf_rect(center: float2, size: float2, p: float2, r: float) -> float:
    q = abs(p - center) - size
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r


def get_normal(sd: float, dx: float, dy: float, thickness: float) -> float3:
    n_cos = max(thickness + sd, 0.0) / thickness
    n_sin = sqrt(1.0 - n_cos * n_cos)
    return normalize(float3(dx * n_cos, dy * n_cos, n_sin))


def height(sd: float, thickness: float) -> float:
    if sd >= 0.0:
        return 0.0
    if sd < -thickness:
        return thickness
    x = thickness + sd
    return sqrt(thickness * thickness - x * x)


def bg(uv: float2, resolution: float2) -> float4:
    if fract(uv.y * resolution.y / 20.0) < 0.5:
        return float4(0.0, 0.5, 1.0, 0.0)
    return float4(0.9, 0.9, 0.9, 0.0)


def main(frag_coord: float2, resolution: float2, mouse: float2) -> float4:
    uv = frag_coord / resolution

    thickness = 14.0
    index = 1.5
    base_height = thickness * 8.0
    color_mix = 0.3
    color_base = float4(1.0, 1.0, 1.0, 0.0)

    center = mouse
    if all(center == float2(0.0)):
        center = resolution * 0.5

    half_size = float2(120.0, 40.0)
    radius = 40.0
    sd = sdf_rect(center, half_size, frag_coord, radius)
    dx = sdf_rect(center, half_size, frag_coord + float2(1.0, 0.0), radius) - sd
    dy = sdf_rect(center, half_size, frag_coord + float2(0.0, 1.0), radius) - sd

    bg_col = mix(float4(0.0), bg(uv, resolution), clamp(sd / 100.0, 0.0, 1.0) * 0.1 + 0.9)
    bg_col.a = smoothstep(-4.0, 0.0, sd)

    normal = get_normal(sd, dx, dy, thickness)

    incident = float3(0.0, 0.0, -1.0)
    refract_vec = refract(incident, normal, 1.0 / index)
    h = height(sd, thickness)
    refract_length = (h + base_height) / dot(float3(0.0, 0.0, -1.0), refract_vec)
    coord1 = frag_coord + refract_vec.xy * refract_length
    refract_color = bg(coord1 / resolution, resolution)

    reflect_vec = reflect(incident, normal)
    c = clamp(abs(reflect_vec.x - reflect_vec.y), 0.0, 1.0)
    reflect_color = float4(c, c, c, 0.0)

    color = mix(mix(refract_color, reflect_color, (1.0 - normal.z) * 2.0), color_base, color_mix)

    color = clamp(color, 0.0, 1.0)
    bg_col = clamp(bg_col, 0.0, 1.0)
    color = mix(color, bg_col, bg_col.a)
    return float4(color.rgb, 1.0)
