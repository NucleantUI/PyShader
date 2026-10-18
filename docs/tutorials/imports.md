# Imports

A shader can import other PyShader modules: helpers in a file next to it,
a package of them, or a library installed with uv, such as the
[standard library](../stdlib/index.md). What the shader uses is compiled
into it as if it were written there, and nothing else is.

This tutorial builds the shader in
[Examples/imports](https://github.com/NucleantUI/PyShader/tree/main/Examples/imports)
one import at a time. Every preview on this page compiles with those files
beside it.

## 1. A module next to the shader

Any `.py` file in the shader's folder is a module, imported by its file name.
`palette.py` holds three colours and a ramp through them:

```py title="Examples/imports/palette.py"
--8<-- "Examples/imports/palette.py"
```

`import palette` makes the module's names reachable as `palette.<name>`,
functions and constants alike:

```pyshader modules="Examples/imports" height="220"
from pyshader import *
import palette


def main(uv: float2, time: float) -> float4:
    t = uv.y + 0.15 * sin(time + uv.x * 3.0)
    return float4(palette.ramp(t), 1.0)
```

A module follows the same rules as a shader: `from pyshader import *` for
the editor, then functions, classes and constants. It has no `main`, and
nothing runs at its top level.

## 2. Importing names

`from module import name` brings a name in to be used on its own. With `as`,
it gets another name. `lighting.py` has two falloffs for distance fields:

```py title="Examples/imports/lighting.py"
--8<-- "Examples/imports/lighting.py"
```

```pyshader modules="Examples/imports" height="220"
from pyshader import *
from lighting import glow, halo as soft


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = (uv - 0.5) * float2(resolution.x / resolution.y, 1.0)
    d = length(p) - 0.2 - 0.03 * sin(time * 2.0)
    light = glow(d, 0.01) + 0.5 * soft(d, 0.08)
    return float4(float3(0.3, 0.6, 1.0) * light, 1.0)
```

Both forms can import the same module: `import palette` and
`from palette import ramp` in one file is fine.

## 3. A package

A folder with an `__init__.py` is a package; its modules import as
`shapes.star`, `shapes.ring`. Inside the package, a module reaches its
siblings with a relative import, as `star.py` does with `polar.py`:

```py title="Examples/imports/shapes/star.py"
--8<-- "Examples/imports/shapes/star.py"
```

The package's `__init__.py` re-exports what it offers and lists it in
`__all__`, so `from shapes import *` brings in exactly `star` and `ring`.
Without an `__all__`, `*` brings every name not starting with `_`:

```py title="Examples/imports/shapes/__init__.py"
--8<-- "Examples/imports/shapes/__init__.py"
```

```pyshader modules="Examples/imports" height="240"
from pyshader import *
from shapes import *


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = (uv - 0.5) * float2(resolution.x / resolution.y, 1.0)
    s = star(p, 5.0 + floor(mod(time, 4.0)), 0.3, 0.5)
    r = ring(p, 0.38, 0.01)
    ink = 1.0 - smoothstep(0.0, 0.01, min(s, r))
    return float4(mix(float3(0.06, 0.05, 0.12), float3(1.0, 0.8, 0.4), ink), 1.0)
```

The same functions are reachable as `shapes.star(...)` after
`import shapes`, or as `shapes.star.star(...)` after `import shapes.star`.

## 4. All together

`orbit.py` uses all three, each imported a different way:

```pyshader file="Examples/imports/orbit.py" modules="Examples/imports" height="300"
```

## 5. Only what is used

Nothing in a module is compiled unless the shader reaches it. `orbit.py` gets
`palette.ramp` and the colours it reads, `glow` and `halo`, and `star`,
`ring` and the `polar.angle_of` that `star` calls. Anything else in those
files costs nothing. A `*` import is no different: it makes names available,
and only the ones used are compiled.

Each imported function keeps its module in its SPIR-V name
(`palette.ramp`, `shapes.star.star`), so it never clashes with the shader's
own names or another module's. An error inside a module names that module's
file and line.

## 6. A library: the standard library

Libraries are installed with uv into the project's `.venv`, where the
compiler looks after the shader's own folder. The
[standard library](../stdlib/index.md) is one:

```toml title="pyproject.toml"
[project]
name = "my-shaders"
version = "0.1.0"
requires-python = ">=3.13"
dependencies = ["pyshader", "pyshader-stdlib"]

[tool.uv]
package = false

[tool.uv.sources]
pyshader = { git = "https://github.com/NucleantUI/PyShader" }
pyshader-stdlib = { git = "https://github.com/NucleantUI/pyshader-stdlib", branch = "master" }
```

```sh
uv sync
```

After that, `pyshader.stdlib` imports like a local module, and local modules
and libraries mix freely:

```pyshader modules="Examples/imports" height="260"
from pyshader import *
import palette
from pyshader.stdlib.fragment.noise import fbm
from pyshader.stdlib.fragment.coords import centered
import pyshader.stdlib.fragment.sdf as sdf


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = centered(uv, resolution)
    clouds = fbm(p * 2.0 + float2(time * 0.1, 0.0), 5)
    sky = palette.ramp(uv.y * 0.8 + clouds * 0.4)
    moon = sdf.sd_moon(p - float2(0.45, 0.35), 0.12, 0.22, 0.2)
    return float4(mix(sky, palette.GOLD, 1.0 - smoothstep(0.0, 0.01, moon)), 1.0)
```

Only packages that declare themselves PyShader modules can be imported from
an environment. An `import numpy` reports that numpy is installed but is not
a PyShader module.

## 7. Writing a library

A library is a Python package with a `pyproject.toml` that declares its
package under the `pyshader.modules` entry point. [Modules](../language/modules.md#writing-a-library)
has the full recipe, including a library that lives under `pyshader` as the
standard library does.

## 8. Building it

- `pyshaderc orbit.py` and `PyShader.compile(contentsOf:target:)` find the
  shader's own folder and the nearest `.venv` on their own. `--site-packages`
  and `modules:` name another environment.
- A Swift package can compile its shaders at build time with the
  [package plugins](../compiler/plugins.md), which watch every module a
  shader can import.
- `PyShader.compile(_:target:modules:)` also takes modules as sources, by
  dotted name, for a host with no files, as the previews on this page do.
