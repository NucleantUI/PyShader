---
title: GLSL to PyShader
hide:
  - navigation
  - toc
---

# GLSL to PyShader

Paste a ShaderToy shader on the left and its PyShader appears on the right.
It all runs in this page: [glslang](https://github.com/KhronosGroup/glslang)
compiles the GLSL to SPIR-V and the [decompiler](compiler/decompiler.md)
turns that back into Python. Pick an example to see what a port looks like.

```pyshader-convert examples="Examples/shadertoy/opengl" height="calc(100vh - 21rem)"
```

## What happens to the GLSL

A `mainImage(out vec4 fragColor, in vec2 fragCoord)` is wrapped in a fragment
shader with NucleantVulkan's layout and ShaderToy's names on top of it:

| ShaderToy | wrapper | PyShader |
|---|---|---|
| `iTime` | push constant `time` | `time` |
| `iResolution` | push constant `resolution` | `resolution` |
| `iMouse.xy` | push constant `mouse` (`.zw` are 0) | `mouse` |
| `fragCoord` | `gl_FragCoord.xy` | `frag_coord.xy` |
| `iFrame`, `iTimeDelta` | `0`, `0.016` | inlined |

A source with its own `#version` line is compiled as it is; its inputs are
named through the [interface table](compiler/decompiler.md#what-comes-back)
and anything the table does not cover keeps its GLSL name, with a warning
under the editors.

The result is a fragment-target shader: `main` takes `frag_coord`, `time`,
`resolution` and `mouse` by name and returns the colour, as in
[Targets → Fragment](targets/fragment.md). Helpers that read the uniforms
get them as trailing parameters, `out` parameters come back as tuple
returns, and `for (int i …)` loops become `range` — the
[decompiler page](compiler/decompiler.md) lists the rewrites. What is not
there: `iChannel*` textures (reported, not translated), `iDate`,
`iSampleRate` and the keyboard texture. `#if` blocks take the branch the
preprocessor picks.

The GLSL that the examples come from is in
[Examples/shadertoy/opengl/](https://github.com/NucleantUI/PyShader/tree/main/Examples/shadertoy/opengl),
next to the hand-written ports in `pyshader/` for comparison.
