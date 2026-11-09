# Python build backend

`pyshader_builder` is a [PEP 517](https://peps.python.org/pep-0517/) build
backend that ships with the `pyshader` package. It compiles a Python
project's shaders while the project is built, the way the
[package plugins](plugins.md) do for a Swift package, and puts the results
in its wheel. An app can then load its OpenGL ES 2 shaders from its own
package, compiled from PyShader modules beside them.

```toml title="pyproject.toml"
[project]
name = "myapp"
version = "0.1.0"
requires-python = ">=3.13"

[build-system]
requires = ["pyshader"]
build-backend = "pyshader_builder"

[tool.uv.sources]
pyshader = { url = "https://github.com/NucleantUI/PyShader/releases/download/0.0.7/pyshader-0.0.7-py3-none-any.whl" }

[tool.pyshader.glow]
source = "src/myapp/shaders/glow.py"
output = "src/myapp/shaders/glow"       # glow.vert and glow.frag
target = "compute"
format = "gles2"
```

The backend's compiler comes in the `pyshader` wheel attached to each
[release](https://github.com/NucleantUI/PyShader/releases), which
`[tool.uv.sources]` points at. A `pyshader` installed from git has the stubs
only, not the compiler. Without uv, name the wheel in the requirement itself:
`requires = ["pyshader @ https://github.com/NucleantUI/PyShader/releases/download/0.0.7/pyshader-0.0.7-py3-none-any.whl"]`.

| command | what happens to the shaders |
|---|---|
| `uv build`, `pip wheel .` | compiled into the wheel, each at its `output` |
| `uv sync`, `pip install -e .` | compiled into the source tree, at each `output`, beside the code that loads it |
| `uv build --sdist` | the sources only; the compiled files are built from them later |

```python
from importlib.resources import files

shaders = files("myapp") / "shaders"
vertex = (shaders / "glow.vert").read_text()
fragment = (shaders / "glow.frag").read_text()
```

## Configuration

The shaders are listed in `[tool.pyshader]` in `pyproject.toml`, or in a
[`pyshader.toml`](plugins.md#pyshadertoml) at the project's root, the file
the SwiftPM plugins read. Use one or the other, not both. The keys are the
same, with paths relative to the project's root:

| key | |
|---|---|
| `source` | the shader's `.py` file |
| `output` | where it goes; inside one of the wheel's packages. Default `<section>.spv`; for `gles2`, `<output>.vert` and `<output>.frag` (its extension replaced), or with `single-file` the one file, `<section>.glsl` by default |
| `format` | `spirv` (default), for Vulkan, or `gles2`: [OpenGL ES 2](gles2.md) |
| `target` | `fragment` (default), `compute` or `graphics` |
| `content`, `content-top-down` | `layer()` reads the content image |
| `textures-top-down` | the `Texture` parameters' images are stored top-down; y-up by default |
| `arguments` | the shader arguments, `["gain:float", "tint:float4"]` |
| `single-file`, `position-attribute`, `uv-varying`, `position-matrices`, … | `gles2`: how the stages are written out, and the names they declare; see [OpenGL ES 2 options](gles2.md#options) |

Outside the sections, `site-packages` names where imported shader libraries
are installed, as in `pyshader.toml`, and `packages` lists the wheel's
package folders when they are not `src/<name>` or `<name>`:

```toml
[tool.pyshader]
packages = ["src/myapp"]
site-packages = ".venv/lib/python3.13/site-packages"
```

`optimize` is not available here. It runs spirv-opt, which only `pyshaderc`
links in. The backend reads `[project]` as written; fields marked `dynamic`
need another backend.

## Imports

A shader imports what `pyshaderc` would find:

1. the `.py` files beside it and below its folder;
2. the packages installed in `site-packages`, or else in the nearest
   `.venv` above the shader, that declare a
   [`pyshader.modules`](../language/modules.md) entry point;
3. the same, installed in the build environment, for a shader library
   listed in `[build-system] requires`.

A library the shaders import is a build dependency, so it goes in
`[build-system] requires`: the build environment always has it, also on the
first `uv sync` and in `uv build`, where the project's `.venv` may not have it
yet. `pyshader` and the library go in the `dev` group too, which `uv sync`
installs into `.venv` by default, so the editor sees the stubs and the
library's functions while you work on the shaders:

```toml
[build-system]
requires = ["pyshader", "pyshader-stdlib"]
build-backend = "pyshader_builder"

[dependency-groups]
dev = ["pyshader", "pyshader-stdlib"]

[tool.uv.sources]
pyshader = { url = "https://github.com/NucleantUI/PyShader/releases/download/0.0.7/pyshader-0.0.7-py3-none-any.whl" }
pyshader-stdlib = { git = "https://github.com/NucleantUI/pyshader-stdlib" }
```

`pyshader-stdlib` installs as `pyshader/stdlib/`, next to the stubs, so
`pyshader` must not be an editable install: an editable one is imported from
its source folder, which has no `stdlib`.

```py
import pyshader.stdlib.fragment.noise as noise
```

## Errors

A shader that does not compile stops the build. The message gives its file,
its line, the line of code, and the section it came from:

```text
src/myapp/shaders/glow.py:2: error: OpenGL ES 2 has no bitwise operators (`&`)
    k = int(uv.x * 8.0) & 3
  in [glow] of pyproject.toml [tool.pyshader], target = "compute", format = "gles2"
```

## How it runs

The compiler is PyShader's Swift one, built to WebAssembly
(`pyshader.wasm`, the module the docs' previews run). It ships inside the
`pyshader` wheel of each release and runs through [wasmtime](https://pypi.org/project/wasmtime/),
which the backend asks the build frontend to install. No Swift toolchain is
needed on the machine that builds. `PYSHADER_WASM` points the backend at
another build of the module.

A PyShader checkout builds the module with:

```sh
uv run scripts/build_wasm.py --only swift   # -> src/pyshader_builder/pyshader.wasm
```

[Examples/kivy_shaders](https://github.com/NucleantUI/PyShader/tree/main/Examples/kivy_shaders)
is a [Kivy](gles2.md#kivy) app built this way, with a gallery of a fragment
shader, a compute shader, and an effect that reads its image through
`layer()`.
