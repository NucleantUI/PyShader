# Modules

A shader project that imports from other PyShader modules
([docs](https://nucleantui.github.io/PyShader/language/modules/)).

| file | what |
|---|---|
| `clouds.py` | the shader: `from noise import fbm`, and `palettes` both ways — `import palettes` and `from palettes import shade, SUNSET` |
| `palettes.py` | a local module — beside the shader, so always importable |
| `packages/pyshader-noise/` | a shader library: a normal Python package whose `pyproject.toml` declares `noise` under the `pyshader.modules` entry point |
| `pyproject.toml` | the project: depends on `pyshader` and `pyshader-noise` (both editable path sources here) |

```sh
cd Examples/modules
uv sync                                        # installs pyshader-noise into .venv
swift run --package-path ../.. pyshaderc clouds.py
spirv-val --target-env vulkan1.0 clouds.spv
```

A site-packages folder elsewhere is passed with `--site-packages <dir>`.

Only what `clouds.py` reaches is compiled: `hash22` in the library and
`unused_debug` in `palettes.py` are not in the SPIR-V. Each definition keeps
its module's qualified name there (`noise.fbm.fbm`, `palettes.shade`).
