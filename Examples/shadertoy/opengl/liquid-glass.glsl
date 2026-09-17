// "Optically correct" liquid glass — https://www.shadertoy.com/view/wccSDf
//
// lq.glsl (Examples/liquid_glass) with two changes so it runs under the
// compute wrapper next to the PyShader port: the pad is a rounded rect
// rather than a capsule, and dFdx/dFdy of the SDF are forward differences
// (no derivatives in a compute shader). The background is the stripes half
// only; there is no iChannel0 here.

float sdfRect(vec2 center, vec2 size, vec2 p, float r)
{
    vec2 p_rel = p - center;
    vec2 q = abs(p_rel) - size;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec3 getNormal(float sd, float dx, float dy, float thickness)
{
    float n_cos = max(thickness + sd, 0.0) / thickness;
    float n_sin = sqrt(1.0 - n_cos * n_cos);
    return normalize(vec3(dx * n_cos, dy * n_cos, n_sin));
}

float height(float sd, float thickness)
{
    if(sd >= 0.0)
    {
        return 0.0;
    }
    if(sd < -thickness)
    {
        return thickness;
    }
    float x = thickness + sd;
    return sqrt(thickness * thickness - x * x);
}

vec4 bg(vec2 uv)
{
    if(fract(uv.y * iResolution.y / 20.0) < 0.5)
    {
        return vec4(0.0, 0.5, 1.0, 0.0);
    }
    else
    {
        return vec4(0.9, 0.9, 0.9, 0.0);
    }
}

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv = fragCoord / iResolution.xy;

    float thickness = 14.0;
    float index = 1.5;
    float base_height = thickness * 8.0;
    float color_mix = 0.3;
    vec4 color_base = vec4(1.0, 1.0, 1.0, 0.0);

    vec2 center = iMouse.xy;
    if(center == vec2(0.0, 0.0))
    {
        center = iResolution.xy * 0.5;
    }

    vec2 half_size = vec2(120.0, 40.0);
    float radius = 40.0;
    float sd = sdfRect(center, half_size, fragCoord, radius);
    float dx = sdfRect(center, half_size, fragCoord + vec2(1.0, 0.0), radius) - sd;
    float dy = sdfRect(center, half_size, fragCoord + vec2(0.0, 1.0), radius) - sd;

    vec4 bg_col = vec4(0.0);
    bg_col = mix(vec4(0.0), bg(uv), clamp(sd / 100.0, 0.0, 1.0) * 0.1 + 0.9);
    bg_col.a = smoothstep(-4., 0., sd);

    vec3 normal = getNormal(sd, dx, dy, thickness);

    vec3 incident = vec3(0.0, 0.0, -1.0);
    vec3 refract_vec = refract(incident, normal, 1.0 / index);
    float h = height(sd, thickness);
    float refract_length = (h + base_height) / dot(vec3(0.0, 0.0, -1.0), refract_vec);
    vec2 coord1 = fragCoord + refract_vec.xy * refract_length;
    vec4 refract_color = bg(coord1 / iResolution.xy);

    vec3 reflect_vec = reflect(incident, normal);
    vec4 reflect_color = vec4(0.0);
    float c = clamp(abs(reflect_vec.x - reflect_vec.y), 0.0, 1.0);
    reflect_color = vec4(c, c, c, 0.0);

    fragColor = mix(mix(refract_color, reflect_color, (1.0 - normal.z) * 2.0),
                    color_base, color_mix);

    fragColor = clamp(fragColor, 0., 1.);
    bg_col = clamp(bg_col, 0., 1.);
    fragColor = mix(fragColor, bg_col, bg_col.a);
}
