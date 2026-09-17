---
title: Playground
hide:
  - navigation
  - toc
  - footer
---

```pyshader-edit height="calc(100vh - 5.6rem)"
from pyshader import *

PI = 3.14159265


def palette(t: float) -> float3:
    return 0.5 + 0.5 * cos(2.0 * PI * (t + float3(0.0, 0.33, 0.67)))


def main(uv: float2, time: float, mouse: float2, resolution: float2) -> float4:
    aspect = resolution.x / resolution.y
    p = (uv - 0.5) * float2(aspect, 1.0)
    m = (mouse / resolution - 0.5) * float2(aspect, 1.0)

    color = float3(0.0)
    for i in range(4):
        q = p * (1.5 + float(i) * 0.5)
        q = fract(q) - 0.5
        d = length(q) * exp(-length(p))
        d = sin(d * 8.0 + time - float(i)) / 8.0
        d = abs(d)
        d = pow(0.01 / d, 1.2)
        color += palette(length(p) + float(i) * 0.4 + time * 0.3) * d

    color *= 1.0 - smoothstep(0.0, 0.4, distance(p, m)) * 0.5
    return float4(color, 1.0)
```
