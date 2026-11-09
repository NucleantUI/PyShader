# Python build backend

`pyshader_builder` is a [PEP 517](https://peps.python.org/pep-0517/) build
backend that ships with the `pyshader` package. It compiles a Python
project's shaders while the project is built, the way the
[package plugins](plugins.md) do for a Swift package, and puts the results
in its wheel. A Kivy app can then load its OpenGL ES 2 shaders from its own
package, compiled from PyShader modules beside them.

```toml title="pyproject.toml"
[project]
name = "myapp"
version = "0.1.0"
requires-python = ">=3.13"
dependencies = ["kivy>=2.3.1"]

[build-system]
requires = ["pyshader"]
build-backend = "pyshader_builder"

[tool.pyshader.glow]
source = "src/myapp/shaders/glow.py"
output = "src/myapp/shaders/glow.glsl"
target = "compute"
format = "gles2"
```

| command | what happens to the shaders |
|---|---|
| `uv build`, `pip wheel .` | compiled into the wheel, each at its `output` |
| `uv sync`, `pip install -e .` | compiled into the source tree, at each `output`, beside the code that loads it |
| `uv build --sdist` | the sources only; the compiled files are built from them later |

```python
from importlib.resources import files

canvas.shader.source = str(files("myapp") / "shaders" / "glow.glsl")
```

## Configuration

The shaders are listed in `[tool.pyshader]` in `pyproject.toml`, or in a
[`pyshader.toml`](plugins.md#pyshadertoml) at the project's root, the file
the SwiftPM plugins read. Use one or the other, not both. The keys are the
same, with paths relative to the project's root:

| key | |
|---|---|
| `source` | the shader's `.py` file |
| `output` | where it goes; inside one of the wheel's packages. Default `<section>.spv`, or `<section>.glsl` for `gles2` |
| `format` | `spirv` (default), for Vulkan, or `gles2`: [OpenGL ES 2](gles2.md), a Kivy `.glsl` file |
| `target` | `fragment` (default), `compute` or `graphics` |
| `content`, `content-top-down` | `layer()` reads the content image (`texture0` in OpenGL ES 2) |
| `arguments` | the shader arguments, `["gain:float", "tint:float4"]` |

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
`pyshader` package and runs through [wasmtime](https://pypi.org/project/wasmtime/),
which the backend asks the build frontend to install. No Swift toolchain is
needed on the machine that builds. `PYSHADER_WASM` points the backend at
another build of the module.

A PyShader checkout builds the module with:

```sh
uv run scripts/build_wasm.py --only swift   # -> src/pyshader_builder/pyshader.wasm
```

[Examples/kivy_shaders](https://github.com/NucleantUI/PyShader/tree/main/Examples/kivy_shaders)
is a Kivy app built this way, with a gallery of a fragment shader, a compute
shader, and an effect that reads its image through `layer()`.
