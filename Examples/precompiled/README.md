# Precompiled shaders

A package whose shaders are compiled to SPIR-V before it runs, from
[`pyshader.toml`](pyshader.toml)
([docs](https://nucleantui.github.io/PyShader/compiler/plugins/)).

| section | source | target |
|---|---|---|
| `tiles` | `Sources/ShaderPack/Shaders/tiles.py`, importing `shapes.py` beside it | compute |
| `ripple` | `../compute/effect_ripple.py` | compute, with `content` |
| `glow` | `../graphics/instanced_glow.py` | graphics, with two `arguments` |

```sh
cd Examples/precompiled
swift run ShaderPack     # the build plugin compiles all three; the app lists them from Bundle.module
swift package --allow-writing-to-package-directory pyshader-compile   # writes Generated/*.spv
```

Edit `shapes.py` and build again: `tiles` is recompiled, the others are not.
