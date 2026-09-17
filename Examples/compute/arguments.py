"""ShaderArguments from Swift: scalars/vectors become parameters, a floatArray is indexed."""


def main(uv: float2, gain: float, tint: float4, mins: FloatArray, mouse: float2, frame: int) -> float4:
    n = len(mins)
    i = int(uv.x * float(n))
    v = mins[i] * gain
    c = tint.rgb * v
    if frame % 2 == 0:
        c += 0.01
    return float4(c, 1.0)
