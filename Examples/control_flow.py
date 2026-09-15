"""if/elif/else, while, for-range, break/continue, early return, nested loops."""


def checker(p: float2, size: float) -> bool:
    ix = int(floor(p.x / size))
    iy = int(floor(p.y / size))
    return (ix + iy) % 2 == 0


def main(uv: float2, time: float, mouse: float2, resolution: float2) -> float4:
    color = float4(0.0, 0.0, 0.0, 1.0)

    if uv.x < 0.25:
        color.r = 1.0
    elif uv.x < 0.5:
        color.g = 1.0
    elif uv.x < 0.75:
        color.b = 1.0
    else:
        color.rgb = float3(1.0)

    if checker(uv, 0.1):
        color.rgb *= 0.8

    # accumulate rings
    acc = 0.0
    i = 0
    while i < 8:
        i += 1
        if i == 3:
            continue
        if i > 6:
            break
        acc += sin(length(uv - 0.5) * 20.0 - time + float(i))

    for k in range(4):
        for j in range(1, 3):
            acc += 0.01 * float(k * j)

    for n in range(10, 0, -2):
        acc += 0.001 * float(n)

    color.rgb += acc * 0.05

    d = distance(uv * resolution, mouse)
    if d < 20.0:
        return float4(1.0, 1.0, 0.0, 1.0)

    return color
