# Control flow

```py
if d < 0.001:
    hit = True
elif d > 20.0:
    break
else:
    t += d

for i in range(64):         # ints; range(start, stop, step) too
    ...
while x >= 0.0:             # float-stepped loops
    x -= 6.67
```

`break`, `continue`, `pass` and early `return` work anywhere, nested loops
included. Every path of a function with a return type must return a value.

There is no `for x in xs` over a list yet — index with `range(len(xs))` —
and no `while … else`, `for … else`, `match`, comprehensions or f-strings:
those are not shader-shaped.

Lowering: `if` becomes `OpSelectionMerge` + `OpBranchConditional`; loops
become `OpLoopMerge` with a header, body and continue block; `break` and
`continue` branch to the merge / continue blocks, and an early `return` inside
a loop is a plain `OpReturnValue` in a block that never reaches the merge.

## In use

A signed-distance sphere marched in a `for` loop with an early `break`, and
a `while` loop that counts rings:

```pyshader
def sphere(p: float3, time: float) -> float:
    c = float3(sin(time) * 0.6, 0.0, 2.5 + cos(time * 0.7))
    return length(p - c) - 0.8


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = (uv - 0.5) * float2(resolution.x / resolution.y, 1.0)
    ro = float3(0.0, 0.0, -1.0)
    rd = normalize(float3(p, 1.2))
    t = 0.0
    hit = False
    for i in range(48):
        d = sphere(ro + rd * t, time)
        if d < 0.002:
            hit = True
            break
        if t > 8.0:
            break
        t += d
    color = float3(0.02, 0.02, 0.05)
    if hit:
        shade = 1.0 - t / 5.0
        color = float3(0.9, 0.4, 0.2) * shade
    else:
        rings = 0
        r = length(p)
        while r > 0.05:
            r -= 0.08
            rings += 1
        if rings % 2 == 0:
            color += 0.03
    return float4(color, 1.0)
```
