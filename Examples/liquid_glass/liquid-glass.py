"""Liquid glass

"Optically correct" liquid glass (shadertoy.com/view/wccSDf) as a
NucleantSwiftUI effect: the view's own rect is the glass pad, and layer(uv)
— the view plus its backdrop — is what the pad refracts. Only the glass part
of the original; its half-strips background and mouse-driven pill are gone.

Arguments: `radius` (corner radius, px), `thickness` (edge bevel, px) and
`inset` (px the pad is smaller than the view on each side). The rim pulls
samples up to ~9 × thickness inward, so a view not much bigger than that
wants a transparent margin — an inset — for the rim to have something to
bend, rather than the edge texel.
"""
from pyshader import *


def sdf_rect(center: float2, size: float2, p: float2, r: float) -> float:
    q = abs(p - center) - size
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r


def surface_normal(sd: float, dx: float, dy: float, thickness: float) -> float3:
    # Cosine and sine between the normal and the xy plane.
    n_cos = clamp((thickness + sd) / thickness, 0.0, 1.0)
    n_sin = sqrt(1.0 - n_cos * n_cos)
    return normalize(float3(dx * n_cos, dy * n_cos, n_sin))


def height(sd: float, thickness: float) -> float:
    if sd >= 0.0:
        return 0.0
    if sd < -thickness:
        return thickness
    x = thickness + sd
    return sqrt(thickness * thickness - x * x)


def main(frag_coord: float2, resolution: float2, radius: float, thickness: float, inset: float) -> float4:
    index = 1.5
    base_height = thickness * 8.0
    color_mix = 0.3
    color_base = float4(1.0, 1.0, 1.0, 0.0)

    center = resolution * 0.5
    size = center - inset - radius
    sd = sdf_rect(center, size, frag_coord, radius)
    # dfdx/dfdy are fragment-only and this is a compute effect: forward
    # differences over one pixel are the same thing.
    dx = sdf_rect(center, size, frag_coord + float2(1.0, 0.0), radius) - sd
    dy = sdf_rect(center, size, frag_coord + float2(0.0, 1.0), radius) - sd
    normal = surface_normal(sd, dx, dy, thickness)

    # A ray going -z hits the top of the pad; where does it hit the
    # z = -base_height plane?
    incident = float3(0.0, 0.0, -1.0)
    refract_vec = refract(incident, normal, 1.0 / index)
    h = height(sd, thickness)
    refract_length = (h + base_height) / dot(incident, refract_vec)
    coord1 = frag_coord + refract_vec.xy * refract_length
    refract_color = layer(coord1 / resolution)

    reflect_vec = reflect(incident, normal)
    c = clamp(abs(reflect_vec.x - reflect_vec.y), 0.0, 1.0)
    reflect_color = float4(c, c, c, 0.0)

    color = mix(mix(refract_color, reflect_color, (1.0 - normal.z) * 2.0), color_base, color_mix)
    color = clamp(color, 0.0, 1.0)
    # Nothing outside the pad; the rim is anti-aliased into it.
    return float4(color.rgb, 1.0 - smoothstep(-1.0, 1.0, sd))
