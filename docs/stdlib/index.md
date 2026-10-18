# Standard library

[pyshader-stdlib](https://github.com/NucleantUI/pyshader-stdlib) is a library
of shader functions written in PyShader: curves, colours, shapes, distance
fields, patterns, noise, and helpers for the vertex stage. It installs under
`pyshader` as `pyshader.stdlib` and imports like any other module (see the
[imports tutorial](../tutorials/imports.md)). Only the functions a shader uses
are compiled into it.

```pyshader height="260"
from pyshader import *
from pyshader.stdlib.fragment.noise import fbm
from pyshader.stdlib.fragment.color import palette
from pyshader.stdlib.fragment.coords import centered
import pyshader.stdlib.fragment.sdf as sdf


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = centered(uv, resolution)
    n = fbm(p * 3.0 + time * 0.15, 5)
    color = palette(n + time * 0.05, float3(0.5), float3(0.5), float3(1.0), float3(0.0, 0.15, 0.3))
    d = sdf.op_smooth_union(sdf.sd_circle(p - float2(0.3 * sin(time), 0.0), 0.25),
                            sdf.sd_box(p + float2(0.3 * sin(time), 0.0), float2(0.2)), 0.15)
    return float4(mix(color * 0.35, color, 1.0 - smoothstep(0.0, 0.01, d)), 1.0)
```

## Install

```toml title="pyproject.toml"
[project]
dependencies = ["pyshader", "pyshader-stdlib"]

[tool.uv.sources]
pyshader = { git = "https://github.com/NucleantUI/PyShader" }
pyshader-stdlib = { git = "https://github.com/NucleantUI/pyshader-stdlib", branch = "master" }
```

`uv sync` puts it in the project's `.venv` as `pyshader/stdlib/`, next to the
`pyshader` stubs, where the compiler and the editor find it. Install both
packages the usual way, not editable: two editable packages under one
`pyshader` hide each other from the editor.

## Two levels

| Import | What is in it |
|---|---|
| [`pyshader.stdlib.fragment.shaping`, `.easing`](shaping.md) | curves that bend a 0..1 value, and animation easing |
| [`pyshader.stdlib.fragment.color`, `.blend`](color.md) | HSB, YUV, palettes, sRGB; layer blend modes |
| [`pyshader.stdlib.fragment.shapes`, `.sdf`](shapes.md) | shapes as masks, and 2D signed distance functions |
| [`pyshader.stdlib.fragment.coords`, `.matrix`, `.pattern`](patterns.md) | centering and polar coordinates, 2D rotation, tiling |
| [`pyshader.stdlib.fragment.random`, `.noise`, `.cellular`](noise.md) | hashes, value / gradient / simplex noise, fBm, Voronoi |
| [`pyshader.stdlib.vertex.*`](vertex.md) | 4x4 transforms, quads from `vertex_index`, deformations |

Functions take their arguments in shader space: `uv` runs 0..1 with y up,
and the shapes and distance functions work around the origin (move the point
to place them: `sd_circle(p - center, r)`).

## Credits

Every module names its sources in its docstring, and the library's
[CREDITS.md](https://github.com/NucleantUI/pyshader-stdlib/blob/master/CREDITS.md)
collects them: The Book of Shaders by Patricio Gonzalez Vivo and Jen Lowe,
whose chapters the `fragment` modules follow; Inigo Quilez's shaping
functions, distance functions and palettes; simplex noise by Ian McEwan
(Ashima Arts) and Stefan Gustavson; Dave Hoskins' hashes; Golan Levin's
shaping functions; Robert Penner's easing equations; the W3C blend modes;
Steven Worley's cellular noise.
