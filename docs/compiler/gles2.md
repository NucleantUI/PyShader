# OpenGL ES 2

The same PyShader module that compiles to SPIR-V also compiles to OpenGL ES 2,
in GLSL ES 1.00. It *is* the SPIR-V: the module is compiled as for Vulkan,
with OpenGL ES 2's entry points, and [Spirv2GLSL](#spirv2glsl) writes that
SPIR-V as GLSL ES 1.00. Everything the language has reaches OpenGL ES 2 the
moment it reaches SPIR-V. What OpenGL ES 2 cannot express is a compile error
at the Python line that needs it, so you find out when you build, not when
the shader fails to compile on a phone.

```sh
swift run pyshaderc shader.py --target compute --format gles2     # -> shader.vert, shader.frag
```

```swift
let shader = try PyShader.compileGLES2(contentsOf: url, target: .nucleantUI)
shader.vertex       // GLSL ES 1.00
shader.fragment
shader.singleFile   // both in one file, after ---VERTEX SHADER--- / ---FRAGMENT SHADER--- lines
```

In a [`pyshader.toml`](plugins.md#pyshadertoml) or a
[Python project](build-backend.md), a section sets `format = "gles2"`.

## What it writes

A vertex stage and a fragment stage, `<output>.vert` and `<output>.frag`.
Each stage is self-contained: it declares what it uses and holds only the
functions its `main()` reaches.

| target | vertex stage | fragment stage |
|---|---|---|
| fragment | written from the [options](#options): a quad passing on `uv` and `color` | `main` with `uv` and `color` from the vertex stage, `frag_coord` = `gl_FragCoord`, `front_facing` = `gl_FrontFacing`; `time`, `resolution`, `mouse` are uniforms |
| compute | written from the options: a quad passing on `uv` | one fragment per pixel of the quad: `uv` from the vertex stage, `frag_coord` = `uv * resolution`, `pixel` y-down from it; `time`, `time_delta`, `frame`, `resolution`, `mouse`, `mouse_click` are uniforms |
| graphics | `vertex`, taking the vertex attributes as `position`, `texcoord` and `color` and uniforms; its first field, through `position-matrices`, to `gl_Position` (GL's clip space is already y-up), the others to `v_<field>` varyings | `fragment`, taking the varyings by name; `uv` = `gl_FragCoord.xy / resolution` |

With the default options, a compute shader's vertex stage is:

```glsl
attribute vec2 a_position;
attribute vec2 a_texcoord;
varying vec2 v_uv;

void main(void) {
    v_uv = a_texcoord;
    gl_Position = vec4(a_position.xy, 0.0, 1.0);
}
```

- **A graphics target's vertices** come from attributes: `vertex` may take
  `position` (a `float2`, or as many floats as `position-size` says),
  `texcoord: float2` and `color: float4`, read from `position-attribute`,
  `texcoord-attribute` and `color-attribute`, and each of `attributes` by its
  own name, beside uniforms and shader arguments. `vertex_index` and `instance_index` have no
  OpenGL ES 2 counterpart. A vertex stage that takes no attribute computes
  the same position for every vertex.
- **The app sets the uniforms.** `resolution` is the quad's size in pixels.
  `mouse` and `mouse_click` are y-up in it.
- **Shader arguments** (`arguments = ["gain:float"]`, `--arg gain:float`)
  become uniforms of the same name.
- **`layer(uv)`** samples the content sampler, `u_content` by default.
  `content = true` reads it as stored, as `texture2D` does;
  `content-top-down` flips the coordinate, as in SPIR-V.
- **A `Texture` parameter** `a` is a `sampler2D a` uniform, read as stored
  unless `textures-top-down` flips it, as in SPIR-V. `a_size` is an `ivec2`
  uniform the app sets, since GLSL ES 1.00 cannot ask a texture its size.
- **`half`** is a `float`: GLSL ES writes precision as a qualifier, which
  desktop GLSL would not take. Every stage starts with
  `precision highp float` under `#ifdef GL_ES`.
- **`dFdx`, `dFdy`, `fwidth`** turn on `GL_OES_standard_derivatives`.
- Python names GLSL keeps for itself (`input`, `sample`, `length`, `half`…)
  get a `_` after them (`input_`), and a shader's own name that an option or
  another declaration takes gets a number (`v_uv_2`). The Python entry point
  is `py_main` (`py_vertex`, `py_fragment`), and `main()` calls it.

## Options

The names the stages declare, how the generated vertex stage places its
quad, and how the stages are written out are options, so the stages link
into whatever program the app has. Each is a key in a `pyshader.toml`
section or `[tool.pyshader]`, a `pyshaderc` flag of the same name, and a
property of `GLES2Options` in Swift:

| key | `pyshaderc` | default | |
|---|---|---|---|
| `single-file` | `--single-file` | `false` | both stages in one file, `<output>.glsl` by default, each after a `---VERTEX SHADER---` / `---FRAGMENT SHADER---` line |
| `uv-top-down` | `--uv-top-down` | `false` | the texture coordinates run top-down: the generated vertex stage passes on `(x, 1 - y)`, so `uv`, and `frag_coord` and `pixel` from it, run up. A graphics target's `texcoord` is the attribute as it is |
| `position-attribute` | `--position-attribute` | `a_position` | the position attribute; a graphics target's `position` |
| `position-size` | `--position-size` | `2` | the floats the position attribute holds, 2, 3 or 4; the generated vertex stage fills in `z = 0`, `w = 1` |
| `attributes` | `--attribute name:kind`, repeated | none | more attributes a graphics target's `vertex` takes, each a parameter of its own name: `["normal:float3", "size:float"]`, kinds `float` to `float4` |
| `texcoord-attribute` | `--texcoord-attribute` | `a_texcoord` | the `vec2` texture coordinate attribute, passed on as `uv`; a graphics target's `texcoord` |
| `color-attribute` | `--color-attribute` | `a_color` | the `vec4` color attribute, passed on as `color`; a graphics target's `color` |
| `color-uniform` | `--color-uniform` | none | a `vec4` uniform the color is instead |
| `opacity-uniform` | `--opacity-uniform` | none | a `float` uniform the color's alpha is multiplied by |
| `position-matrices` | `--position-matrix`, repeated | none | `mat4` uniforms the position is multiplied by, left to right, in the generated vertex stage and after a graphics target's `vertex`; none: it is already in clip space |
| `uv-varying` | `--uv-varying` | `v_uv` | the varying `uv` is read from |
| `color-varying` | `--color-varying` | `v_color` | the varying `color` is read from |
| `content-sampler` | `--content-sampler` | `u_content` | the `sampler2D` `layer()` samples |

The vertex stage declares only what the fragment stage reads: no
`a_texcoord` for a shader that never takes `uv`, no color for one that never
takes `color`. A name must be one GLSL lets a shader declare, and no two
options may share one.

### Kivy

[Kivy](https://kivy.org) loads both stages from one file with `Shader.source`,
and links them with its vertex format and the uniforms its canvas sets. These
settings fit a shader to it:

```toml
format = "gles2"
single-file = true
uv-top-down = true               # a Rectangle's tex_coords, and an image's, run top-down
position-attribute = "vPosition"
texcoord-attribute = "vTexCoords0"
position-matrices = ["projection_mat", "modelview_mat"]
uv-varying = "tex_coord0"
color-varying = "frag_color"     # fragment target, `color`
color-uniform = "color"          # the canvas's `Color`
opacity-uniform = "opacity"      # the widget's opacity
content-sampler = "texture0"     # the texture Kivy binds, for layer()
content-top-down = true          # an image Kivy loads is stored top-down
```

```python
from kivy.graphics import RenderContext

canvas = RenderContext(use_parent_projection=True, use_parent_modelview=True)
canvas.shader.source = "shader.glsl"
canvas["time"] = 1.5                      # a uniform the shader takes
canvas["resolution"] = [800.0, 600.0]
```

A graphics target draws a `Mesh` in a `RenderContext`: its default vertex
format is `vPosition` and `vTexCoords0`, which `vertex` takes as `position`
and `texcoord`, in the widget's coordinates, which `position-matrices` takes
to the screen. A mesh with its own `fmt` names its attributes:

```toml
# Mesh(fmt=[(b"v_pos", 3, "float"), (b"v_normal", 3, "float"), (b"size", 1, "float")])
position-attribute = "v_pos"
position-size = 3
attributes = ["v_normal:float3", "size:float"]
```

```py
def vertex(position: float3, v_normal: float3, size: float) -> V: ...
```

A Kivy `ShaderTransition` sets a `t` uniform and two textures:
`def main(uv: float2, t: float, tex_in: Texture, tex_out: Texture)` with
`arguments = ["t:float"]` declares them.
[Examples/kivy_shaders](https://github.com/NucleantUI/PyShader/tree/main/Examples/kivy_shaders)
is a Kivy app built this way.

## What OpenGL ES 2 cannot express

GLSL ES 1.00, and the minimum every OpenGL ES 2 device supports
([Appendix A of its specification](https://registry.khronos.org/OpenGL/specs/es/2.0/GLSL_ES_Specification_1.00.pdf)),
rules these out. Each one is an error at its line:

| PyShader | in OpenGL ES 2 |
|---|---|
| `while` | only `for` loops are guaranteed: write `for i in range(N):` with a `break` |
| `range(n)` with `n` computed at run time | loop bounds must be constants (arithmetic on constants, `RADIUS + 1`, is fine); loop to a constant maximum and `break` |
| assigning a loop counter in the loop | the counter is constant in the body |
| `xs[i]`, `v[i]` with `i` computed at run time | indices are constants and `for` counters, or expressions of them |
| `uint`, `short`, `ushort` | no unsigned or 16-bit integers |
| `&`, `\|`, `^`, `~`, `<<`, `>>` on integers | no bitwise operators (on bools they are `&&`, `\|\|`, `^^`) |
| `float2x3` and other non-square matrices | square matrices only |
| `transpose`, `determinant`, `inverse` | no matrix functions |
| `isnan`, `isinf`, `modf`, `frexp`, `ldexp`, packing, bit functions | not in GLSL ES 1.00 |
| fine and coarse derivatives | only `dFdx`, `dFdy`, `fwidth` |
| array arguments (`FloatArray`), class and list inputs | uniforms have a fixed size, and there are no storage buffers |
| `vertex_index`, `instance_index` | no `gl_VertexID`, no instancing: take the vertex attributes, `position`, `texcoord`, `color` |
| integer or bool varyings | only floats are interpolated |
| a function returning a list, a class or tuple holding one | arrays cannot be returned, nor structs holding them assigned |

Some things it lacks are written out instead, with the same results:

- `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh`, `trunc` and `round`
  are written out in what GLSL ES 1.00 has. `round` rounds half to even, as
  Python does.
- A loop counter read after the loop holds what Python says it does: the
  variable steps beside the `for` loop's own index.
- `abs`, `sign`, `min`, `max`, `clamp`, `//` and `%` on integers go through
  floats, since GLSL ES 1.00 has them for floats only. They are exact for
  the integer range OpenGL ES 2 promises.
- `match` becomes an `if` chain, since there is no `switch`.
- A list literal fills a local array element by element, since there is no
  array constructor. A list is assigned element by element.
- `float3x3(m)` from another matrix is built column by column.

For example, a bitwise `&` stops the build at its line:

```text
glow.py:2: error: a bitwise operation has no OpenGL ES 2 form
    k = int(uv.x * 8.0) & 3
```

## Spirv2GLSL

The translator is a library of its own, `Spirv2GLSL` in this package, and a
command, `spirv2glslc`. It reads SPIR-V alone, whichever compiler wrote it
(PyShader, glslang, a Metal or HLSL shader compiled to SPIR-V), and writes
its vertex and fragment stages as GLSL ES 1.00:

```sh
swift run spirv2glslc shader.spv -o shader          # -> shader.vert, shader.frag
swift run spirv2glslc shader.spv --stage fragment   # one stage, to stdout
```

```swift
import Spirv2GLSL

let translator = try GLSLESTranslator(spirv: words)
let vertex = try translator.translate(stage: .vertex)
// OpenGL ES 2 links varyings by name: the fragment stage takes the vertex stage's.
let fragment = try translator.translate(stage: .fragment, varyingNames: vertex.varyingNames)
```

| SPIR-V | GLSL ES 1.00 |
|---|---|
| `Input` of a vertex stage | `attribute`, under its `OpName` |
| `Input` of a fragment stage, `Output` of a vertex stage | `varying` |
| `Output` of a fragment stage at location 0 | `gl_FragColor` |
| built-ins `Position`, `PointSize`, `FragCoord`, `FrontFacing`, `PointCoord` | `gl_Position`, `gl_PointSize`, `gl_FragCoord`, `gl_FrontFacing`, `gl_PointCoord` |
| a `Uniform` block, push constants | one uniform per member read, under the member's name |
| a sampled image, or an image an `OpSampledImage` pairs with a sampler | `uniform sampler2D` / `samplerCube` |
| `Private` variables | globals |
| `OpImageQuerySize` | an `ivec2` uniform `<sampler>_size` the app sets |

Structured control flow becomes `if` / `else if` (a switch too), phis
variables, loops Appendix A `for` loops. `loopsFollowAppendixA = false`
(`--any-loops`) writes any other loop as `while (true)`, for drivers that run
them, instead of refusing it. `#version` and the float precision are options;
with no `#version` the source also compiles as desktop GLSL.
