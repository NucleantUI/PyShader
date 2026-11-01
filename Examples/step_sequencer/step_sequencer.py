"""A step sequencer's 64 pads in one instanced draw — NucleantUI's VertexShader.

    pyshaderc step_sequencer.py --target graphics

`steps` is the shader's input: a list of `Step`, one per pad, drawn with
`vertices: 6, instances: 64`. The host writes the steps one after another
at `Step`'s std430 stride, 32 bytes: `color` at 0, `flags` at 16. In
NucleantUI that is a `ShaderInput` packing an array of the steps.

`flags` bit 0 is the step being on, bit 1 the clock being on it; bits 2 and
3 are spare. The vertex stage places pad `instance_index` on a 16 x 4 grid,
row by row from the top, and hands its flags on as 0 or 1 floats; the
fragment stage rounds the pad, dims it when it is off and brightens the one
the clock is on.
"""
from pyshader import *

COLUMNS = 16
ROWS = 4
ON = 1
LIT = 2

QUAD = [float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
        float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)]


class Step:
    color: float4
    flags: uint


class Pad:
    position: float4
    local: float2
    color: float4
    # x: on, y: lit by the clock.
    state: float2


def vertex(vertex_index: int, instance_index: int, steps: list[Step]) -> Pad:
    pad = steps[instance_index]
    column = instance_index % COLUMNS
    row = instance_index // COLUMNS
    # The cell's centre in clip space, y-up, the first row at the top.
    cell = float2(2.0 / COLUMNS, 2.0 / ROWS)
    centre = float2((float(column) + 0.5) * cell.x - 1.0, 1.0 - (float(row) + 0.5) * cell.y)
    corner = QUAD[vertex_index]
    return Pad(
        position=float4(centre + corner * cell * 0.42, 0.0, 1.0),
        local=corner,
        color=pad.color,
        state=float2(float(pad.flags & ON), float((pad.flags & LIT) >> 1)),
    )


def fragment(local: float2, color: float4, state: float2) -> float4:
    # A rounded square: the distance to a box whose corners are cut by `r`.
    r = 0.3
    q = abs(local) - (1.0 - r)
    d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r
    inside = smoothstep(0.05, -0.05, d)

    rgb = color.rgb * mix(0.2, 1.0, state.x)
    rgb = mix(rgb, float3(1.0), 0.5 * state.y)
    return float4(rgb, color.a * inside)
