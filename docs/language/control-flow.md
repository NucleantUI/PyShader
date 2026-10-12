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
for i in unroll(range(4)):  # a hint; dont_unroll(range(n)) is the other one
    ...
while x >= 0.0:             # float-stepped loops
    x -= 6.67

match band:                 # an int or uint
    case 0:
        color = red
    case 1 | 2:
        color = green
    case _:
        color = blue
```

`break`, `continue`, `pass` and early `return` work anywhere, nested loops
included. Every path of a function with a return type must return a value.

`match` takes an `int` or `uint` subject (a `short` / `ushort` widens).
A case is int literals joined by `|`, or `_`, which must come last. Cases
don't fall through, as in Python, and a value repeated in a later case
belongs to the first one. There are no capture (`case n:`), class or
sequence patterns, and no guards (`case 1 if c:`, which the parser does not
read yet). `break` and `continue` in a case act on the enclosing loop.

There is no `for x in xs` over a list yet; index with `range(len(xs))`.
There is no `while … else`, `for … else`, comprehension or f-string: those
are not shader-shaped.

Lowering: `if` becomes `OpSelectionMerge` + `OpBranchConditional`; loops
become `OpLoopMerge` with a header, body and continue block; `break` and
`continue` branch to the merge / continue blocks, and an early `return` inside
a loop is a plain `OpReturnValue` in a block that never reaches the merge.
`unroll()` / `dont_unroll()` set the loop's `Unroll` / `DontUnroll` control,
hints that change nothing the loop computes.
`match` becomes `OpSelectionMerge` + `OpSwitch`, `case _` its default. A
`break` in a case sets a flag and leaves the switch, and the loop is left
right after it: naga (the web build) would turn a branch from a case straight
to the loop's merge into a WGSL `break`, which only leaves the switch.

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
