"""`main` with no return forwards the `color` input unchanged when it does not return."""


def main(color: float4, uv: float2):
    if uv.x > 0.5:
        return float4(color.rgb * 0.5, color.a)
    return
