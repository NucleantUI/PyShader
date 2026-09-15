def main(uv: float2, time: float) -> float4:
    # this is per pixel call
    color = float4(1, 0, 0, 1)
    color.rgb *= 0.5

    color.rgb = color.rgb + 0.5

    color.r = color.r / 2
    return color
