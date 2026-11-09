# Kivy shaders

A Kivy app whose shaders are PyShader modules. `pyshader_builder`, PyShader's
PEP 517 build backend, compiles them to OpenGL ES 2 (GLSL ES 1.00, what Kivy
draws with) whenever the app is built or installed.

| file | what |
|---|---|
| `pyproject.toml` | `build-backend = "pyshader_builder"`, and a `[tool.pyshader.<name>]` table per shader with `format = "gles2"` |
| `src/kivy_shaders/shaders/plasma.py` | a fragment target: `uv` and `color` come from Kivy's default vertex shader |
| `src/kivy_shaders/shaders/aurora.py` | a compute target: one fragment per pixel, a `for` loop over a constant range, the pointer as a light |
| `src/kivy_shaders/shaders/ripple.py` | a compute target with `content = true`: `layer()` reads the image under the shader; `strength` is a shader argument |
| `src/kivy_shaders/shaders/palette.py` | a local module the other shaders import |
| `src/kivy_shaders/app.py` | the gallery: a `RenderContext` per shader, `shader.source` set to the compiled `.glsl`, the uniforms set every frame |

```sh
cd Examples/kivy_shaders
uv sync                   # editable install: writes shaders/*.glsl beside the .py files
uv run kivy-shaders
uv build                  # the wheel carries the compiled .glsl files
```

The `pyshader` source points at this repository, whose `src/pyshader_builder/`
needs the compiler built first: `uv run scripts/build_wasm.py --only swift`
at the repository root.

A shader that uses what OpenGL ES 2 lacks stops the build at its line:

```text
src/kivy_shaders/shaders/aurora.py:22: error: OpenGL ES 2 only guarantees `for` loops over a constant `range()` (GLSL ES 1.00, Appendix A), not `while`; write it as `for i in range(N):` with a `break`
    while i < BANDS:
  in [aurora] of pyproject.toml [tool.pyshader], target = "compute", format = "gles2"
```
