"""Classic plasma. Uses push constants (time, resolution) and the uv input."""

SPEED = 0.7


def palette(t: float) -> float3:
    a = float3(0.5, 0.5, 0.5)
    b = float3(0.5, 0.5, 0.5)
    c = float3(1.0, 1.0, 1.0)
    d = float3(0.263, 0.416, 0.557)
    return a + b * cos(2.0 * PI * (c * t + d))


def main(uv: float2, time: float, resolution: float2) -> float4:
    aspect = resolution.x / resolution.y
    p = float2(uv.x * aspect, uv.y)
    t = time * SPEED
    v = sin(p.x * 10.0 + t)
    v += sin((p.y * 10.0 + t) / 2.0)
    v += sin((p.x * 10.0 + p.y * 10.0 + t) / 2.0)
    cx = p.x + 0.5 * sin(t / 5.0)
    cy = p.y + 0.5 * cos(t / 3.0)
    v += sin(sqrt(100.0 * (cx * cx + cy * cy) + 1.0) + t)
    v = v / 2.0
    return float4(palette(v), 1.0)
