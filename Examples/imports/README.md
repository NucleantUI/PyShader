# Imports

The example the [imports tutorial](https://nucleantui.github.io/PyShader/tutorials/imports/) builds:
a shader, `orbit.py`, and the modules beside it.

| File | What it shows |
|---|---|
| `palette.py` | a module of constants and a function: `import palette`, then `palette.ramp(...)` |
| `lighting.py` | a module whose functions are imported by name: `from lighting import glow, halo` |
| `shapes/` | a package: `__init__.py` re-exports `star` and `ring` and lists them in `__all__`, so `from shapes import *` brings exactly those; `star.py` uses the package's own `polar.py` through a relative import |
| `orbit.py` | the shader importing all three |

```sh
swift run pyshaderc Examples/imports/orbit.py --target compute
```

Only what `orbit.py` uses ends up in the SPIR-V: `palette.ramp` (with the
colours it reads), `lighting.glow` and `halo`, and `shapes.star`, `ring` and
the `polar.angle_of` that `star` calls.
