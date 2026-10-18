# Modules

A shader can import functions, constants and classes from other PyShader
modules: plain `.py` files written in the same subset. What the shader uses
is compiled into it as if it were written there; everything else is left
out.

```py
from pyshader import *
from noise import fbm          # one name
import palettes                # palettes.shade(...), palettes.OCEAN
from shaderlib.sdf import *    # only the names the code uses

def main(uv: float2, time: float) -> float4:
    d = fbm(uv * 4.0 + time)
    return float4(palettes.shade(palettes.OCEAN, d), 1.0)
```

The same rules apply in a module as in a shader: it may define functions,
classes and constants (and variables a function declares `global`), and
import `pyshader` and other PyShader modules — nothing from the Python
standard library or any other Python package. The entry points (`main`,
`vertex`, `fragment`) are defined in the shader itself; a module's `main` is
just a function.

## Import forms

| form | binds |
|---|---|
| `import noise` | `noise.fbm(...)`, `noise.SCALE`, `noise.Ray` (as a constructor or an annotation) |
| `import noise as n` | `n.fbm(...)` |
| `import shaderlib.noise` | `shaderlib.noise.fbm(...)` |
| `from noise import fbm, SCALE as K` | `fbm(...)`, `K` |
| `from shaderlib import noise` | the submodule, `noise.fbm(...)` |
| `from noise import *` | every public name (or the ones in `__all__`) that the code actually uses |
| `from .hash import hash21` | inside a package: relative to it |

A package is a folder with an `__init__.py`; what its `__init__.py` imports
it re-exports (`from .fbm import fbm` there makes `from noise import fbm`
work). Modules may import each other in a circle.

Names follow Python's scoping: a function's parameters and the names it
assigns are its own, so a local `hash` does not reach a module's `hash`, and
the shader's own definitions win over names a `*` brings in. A name two `*`
imports both provide is an error where it is used; import it by name.

## Only what is used

Each definition the shader reaches — directly or through the modules'
own functions — is compiled once, under its module's qualified name
(`noise.fbm`, `shaderlib.noise.hash21`). That is the name in the SPIR-V
(`OpName`) and in error messages, and since it contains a `.` it never clashes
with the shader's names or another module's: two modules may each have a
`hash`. A function nothing calls is not compiled, so it does not have to be
valid for the targets the shader is built for.

## Where modules are found

In order:

1. the folder of the shader file being compiled — a module next to it imports by its file name;
2. a site-packages folder: the one given (`modules:` in Swift,
   `--site-packages` to `pyshaderc`), or else the one of the nearest `.venv`
   above the shader (or of `VIRTUAL_ENV` when there is none) — where
   `uv add` installs libraries, editable installs (`uv add --editable`)
   included, which it follows through their `.pth` file.

An environment holds every kind of Python package, so from site-packages
only the packages that declare themselves PyShader modules can be imported;
`import numpy` says it is installed but is not a PyShader module.

## Writing a library

A shader library is an ordinary Python package with a `pyproject.toml`. It
depends on `pyshader` (for the editor) and on any other shader library it
imports, and declares its top-level package under the `pyshader.modules`
entry point group:

```toml title="pyproject.toml"
[project]
name = "pyshader-noise"
version = "0.1.0"
dependencies = ["pyshader"]

[project.entry-points."pyshader.modules"]
noise = "noise"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/noise"]
```

```py title="src/noise/__init__.py"
from .fbm import fbm
from .value import value_noise

__all__ = ["fbm", "value_noise"]
```

A shader project lists its libraries as dependencies and `uv sync` installs
them into its `.venv`, where the compiler — and the editor, for completion —
find them:

```sh
uv add pyshader-noise                          # or: uv add --editable ../pyshader-noise
uv sync
swift run pyshaderc clouds.py                  # finds noise in .venv
```

[Examples/modules](https://github.com/NucleantUI/PyShader/tree/main/Examples/modules)
is such a project: a shader, a local module beside it, and a library in
`packages/pyshader-noise`.

## Errors and source lines

An error inside a module names its file, relative to the folder it was found
in: ``noise/fbm.py, line 12: unknown function `nope` ``. When the shader is
compiled with its file name (`sourceFile:`, or `pyshaderc`), every module
file a compiled statement comes from gets its own `OpString`, and its
statements' `OpLine`s point there.

## From Swift

```swift
// A file on disk: its folder, then the nearest .venv's site-packages.
let shader = try PyShader.compile(contentsOf: url, target: .nucleantUI)

// Source in memory, its modules from a site-packages folder (a URL or a path):
let shader = try PyShader.compile(source, target: .nucleantUI, modules: sitePackagesURL)
let shader = try PyShader.compile(source, target: .nucleantUI, modules: ".venv/lib/python3.13/site-packages")
```

Without `modules:`, a source string can import nothing besides `pyshader`.

The web previews on this site compile a single source with no modules, so
the examples on this page are not live.
