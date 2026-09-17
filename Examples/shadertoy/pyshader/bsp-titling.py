"""Random BSP tiling

https://www.shadertoy.com/view/cdsXDr — Tom'2017. Port of opengl/bsp-titling.glsl
with USE_COLORS 2 and CURVED 1 taken. mat3 becomes float3x3; iTime is passed down
to the helpers that read it.
"""
from pyshader import *

ANIM_SPEED = 8.0

iterations = 64
dist_eps = 0.001
ray_max = 200.0
fog_density = 0.04
fog_start = 16.0

cam_dist = 13.5

# ---------------------------------------------
# Tiling code

# Do N splits resulting 2^N areas.
N = 14
# Lacunarity
lac = 0.78


def dTile(p: float2, time: float) -> float2:
    p_scale = pow(lac, float(N)) * 4.0
    p *= p_scale

    # Start at the center with normal vector up.
    split_c = float2(0.0)
    split_n = float2(0.0, 1.0)
    split_d = 4.0

    min_d = 99.0

    cell = float4(0.0)

    for i in range(N):
        dp = p - split_c
        perp_n = float2(-split_n.y, split_n.x)

        # Parametrization:
        u = dot(dp, perp_n)
        v = dot(dp, split_n)

        # Sign distance to edge:
        s = pow(1.0 / lac, float(i))
        d = v + sin(u * 2.0 * s + sin(u * s) * (1.5 + sin(time * ANIM_SPEED))) * 0.1 / s

        cell.xyz = float3(u, v, d)

        # Find min. abs distance:
        min_d = min(min_d, abs(d))

        # Calculate next split center.
        side = sign(d)
        cell.w += (side + 1.0) * split_d
        split_c += side * split_n * split_d
        split_n = normalize(perp_n + float2(0.1, 0.3))
        split_d *= lac

    return float2(cell.w * 1.5, min_d / p_scale * 0.8)


# ---------------------------------------------

bump = 0.15
ground = 0.2


def dField(p: float3, time: float) -> float:
    d = p.y + ground

    tile = dTile(p.xz, time)
    d3 = min(0.05, tile.y) * 0.5
    d3 += tile.y * 0.45
    d3 = min(d3, bump)
    d -= d3
    return d


def dNormal(p: float3, eps: float, time: float) -> float3:
    e = float2(eps, 0.0)
    return normalize(float3(
        dField(p + e.xyy, time) - dField(p - e.xyy, time),
        dField(p + e.yxy, time) - dField(p - e.yxy, time),
        dField(p + e.yyx, time) - dField(p - e.yyx, time)))


def trace(ray_start: float3, ray_dir: float3, time: float) -> float4:
    ray_len = 0.0
    p = ray_start

    # Intersect with ground plane first
    if ray_dir.y >= 0.0:
        return float4(0.0)

    dist = (ray_start.y + ground - bump) / -ray_dir.y
    p += dist * ray_dir
    ray_len += dist
    if ray_len > ray_max:
        return float4(0.0)

    for i in range(iterations):
        dist = dField(p, time)
        if dist < dist_eps * ray_len:
            break
        if ray_len > ray_max:
            return float4(0.0)
        p += dist * ray_dir
        ray_len += dist
    return float4(p, ray_len)


def shade(ray_start: float3, ray_dir: float3, light_dir: float3, fog_color: float3, hit: float4, time: float) -> float3:
    dir = hit.xyz - ray_start
    norm = dNormal(hit.xyz, 0.015, time)
    diffuse = max(0.0, dot(norm, light_dir))
    spec = max(0.0, dot(reflect(light_dir, norm), normalize(dir)))
    spec = pow(spec, 32.0) * 0.7

    tile = dTile(hit.xz, time)
    sh = tile.x
    sh = (abs(mod(sh + 6.0, 12.0) - 6.0) + 2.5) * (1.0 / 9.0)
    sd = min(tile.y, 0.05) * 20.0
    # Ken Silverman's EvalDraw colors ;)
    base_color = float3(exp(pow(sh - 0.75, 2.0) * -10.0),
                        exp(pow(sh - 0.50, 2.0) * -20.0),
                        exp(pow(sh - 0.25, 2.0) * -10.0))
    color = mix(float3(0.0), float3(1.0), diffuse) * base_color + spec * float3(1.0, 1.0, 0.9)
    color *= sd

    fog_dist = max(0.0, length(dir) - fog_start)
    fog = 1.0 - 1.0 / exp(fog_dist * fog_density)
    color = mix(color, fog_color, fog)

    return color


def main(frag_coord: float2, resolution: float2, time: float, mouse: float2, mouse_click: float2) -> float4:
    uv = (frag_coord - resolution * 0.5) / resolution.y

    light_dir = normalize(float3(0.5, 1.0, 0.25))

    # Simple model-view matrix:
    ms = 2.5 / resolution.y
    pressed = mouse_click.x > 0.0
    ang = (mouse.x - resolution.x * 0.5) * -ms if pressed else -time * 0.25
    si = sin(ang)
    co = cos(ang)
    cam_mat = float3x3(
        co, 0.0, si,
        0.0, 1.0, 0.0,
        -si, 0.0, co)
    ang = (mouse.y - resolution.y) * -ms - 0.1 if pressed else cos(-time * 0.5) * 0.4 + 0.8
    ang = max(0.0, ang)
    si = sin(ang)
    co = cos(ang)
    cam_mat = cam_mat * float3x3(
        1.0, 0.0, 0.0,
        0.0, co, si,
        0.0, -si, co)

    pos = cam_mat * float3(0.0, 0.0, -cam_dist)
    dir = normalize(cam_mat * float3(uv, 1.0))

    fog_color = float3(min(1.0, 0.4 + max(-0.1, dir.y * 0.8)))
    hit = trace(pos, dir, time)
    if hit.w == 0.0:
        color = fog_color
    else:
        color = shade(pos, dir, light_dir, fog_color, hit, time)

    # gamma correction:
    color = pow(color, float3(0.7))

    return float4(color, 1.0)
