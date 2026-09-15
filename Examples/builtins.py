"""Touches every builtin so the api-status doc stays honest."""


def main(uv: float2, time: float, frag_coord: float4) -> float4:
    p = uv * 2.0 - 1.0
    a = sin(p.x) + cos(p.y) + tan(0.1) + asin(0.1) + acos(0.1) + atan(0.1) + atan(p.y, p.x) + atan2(p.y, p.x)
    a += sinh(0.1) + cosh(0.1) + tanh(0.1) + asinh(0.1) + acosh(1.5) + atanh(0.1)
    a += radians(90.0) + degrees(1.0)
    a += pow(2.0, 3.0) + exp(1.0) + exp2(3.0) + log(2.0) + log2(8.0) + sqrt(4.0) + inversesqrt(4.0) + rsqrt(4.0)
    a += abs(-1.0) + sign(-2.0) + floor(1.5) + ceil(1.5) + round(1.5) + trunc(-1.5) + fract(1.25) + mod(5.0, 3.0)
    a += min(1.0, 2.0, 0.5) + max(1.0, 2.0) + clamp(5.0, 0.0, 1.0) + saturate(2.0)
    a += mix(0.0, 1.0, 0.5) + lerp(0.0, 1.0, 0.5) + step(0.5, p.x) + smoothstep(0.0, 1.0, p.x) + fma(1.0, 2.0, 3.0)
    a += float(isnan(a)) + float(isinf(a))
    a += float(abs(-3)) + float(sign(-3)) + float(min(1, 2)) + float(max(1, 2)) + float(clamp(5, 0, 1))

    v = float3(p, 1.0)
    g = length(v) + distance(v, float3(0.0)) + dot(v, v)
    n = normalize(cross(v, float3(0.0, 1.0, 0.0)))
    n = reflect(n, float3(0.0, 0.0, 1.0)) + refract(n, float3(0.0, 0.0, 1.0), 0.9) + faceforward(n, v, n)

    b = any(v > 0.5) or all(v < 2.0)
    d = dfdx(p.x) + dfdy(p.y) + fwidth(p.x) + dFdx(p.y) + dFdy(p.x)

    vm = min(v, 0.5) + max(v, float3(0.1)) + clamp(v, 0.0, 1.0) + smoothstep(0.0, 1.0, v) + pow(v, 2.0) + abs(v)

    if frag_coord.x < 1.0:
        discard()

    c = float3(a * 0.001 + g * 0.01 + d) + vm * 0.1 + n * 0.1
    c.r += 0.1 if b else 0.0
    return float4(c, 1.0)
