# OpenGL ES 2

The same PyShader module that compiles to SPIR-V also compiles to OpenGL ES 2,
in GLSL ES 1.00, the shading language [Kivy](https://kivy.org) draws with.
It goes through the same parser and the same checks. What OpenGL ES 2 cannot
express is a compile error at the Python line that needs it, so you find out
when you build, not when the shader fails to compile on a phone.

```sh
swift run pyshaderc shader.py --target compute --format gles2     # -> shader.glsl
```

```swift
let shader = try PyShader.compileGLES2(contentsOf: url, target: .nucleantUI)
shader.vertex       // GLSL ES 1.00
shader.fragment
shader.kivySource   // both, as one Kivy .glsl file
```

In a [`pyshader.toml`](plugins.md#pyshadertoml) or a
[Python project](build-backend.md), a section sets `format = "gles2"`.

## What it writes

A Kivy single-file shader: a `---VERTEX SHADER---` and a
`---FRAGMENT SHADER---` section, which `Shader.source` loads:

```python
from kivy.graphics import RenderContext

canvas = RenderContext(use_parent_projection=True, use_parent_modelview=True)
canvas.shader.source = "shader.glsl"
canvas["time"] = 1.5                      # a uniform the shader takes
canvas["resolution"] = [800.0, 600.0]
```

Each stage is self-contained, with no `$HEADER$`. It declares what it uses
under Kivy's names and holds only the functions its `main()` reaches.

| target | vertex stage | fragment stage |
|---|---|---|
| fragment | Kivy's default vertex shader, written out | `main` with `uv` = `tex_coord0`, `color` = `frag_color`, `frag_coord` = `gl_FragCoord`, `front_facing` = `gl_FrontFacing`; `time`, `resolution`, `mouse` are uniforms |
| compute | Kivy's default vertex shader | one fragment per pixel of the widget: `uv` = `tex_coord0`, `frag_coord` = `uv * resolution`, `pixel` y-down from it; `time`, `time_delta`, `frame`, `resolution`, `mouse`, `mouse_click` are uniforms |
| graphics | `vertex`, its first field to `gl_Position` (GL's clip space is already y-up), the others to `v_<field>` varyings | `fragment`, taking the varyings by name; `uv` = `gl_FragCoord.xy / resolution` |

- **The app sets the uniforms.** `resolution` is the widget's size in pixels.
  `mouse` and `mouse_click` are y-up in the widget, as Kivy's touch positions
  are once the widget's position is subtracted.
- **Shader arguments** (`arguments = ["gain:float"]`, `--arg gain:float`)
  become uniforms of the same name.
- **`layer(uv)`** samples `texture0`, the texture Kivy binds: the
  `Rectangle`'s, or the `Fbo`'s. `content = true` reads it as stored, as
  `texture2D` does; `content-top-down` flips the coordinate, as in SPIR-V.
- **A `Texture` parameter** `a` is a `sampler2D a` uniform, read as stored
  unless `textures-top-down` flips it, as in SPIR-V. `a_size` is an `ivec2`
  uniform the app sets, since GLSL ES 1.00 cannot ask a texture its size.
  A Kivy `ShaderTransition` is one: `def main(uv: float2, t: float, tex_in: Texture, tex_out: Texture)`
  with `arguments = ["t:float"]` declares the `t`, `tex_in` and `tex_out` it sets.
- **`half`** is a `float`: GLSL ES writes precision as a qualifier, which the
  desktop GLSL Kivy compiles on a computer would not take. Every stage
  starts with Kivy's `precision highp float`.
- **`dFdx`, `dFdy`, `fwidth`** turn on `GL_OES_standard_derivatives`.
- Python names GLSL keeps for itself (`input`, `sample`, `length`, `half`…)
  are renamed with a `py_` prefix. The Python entry point is `py_main`
  (`py_vertex`, `py_fragment`), and `main()` calls it.

## What OpenGL ES 2 cannot express

GLSL ES 1.00, and the minimum every OpenGL ES 2 device supports
([Appendix A of its specification](https://registry.khronos.org/OpenGL/specs/es/2.0/GLSL_ES_Specification_1.00.pdf)),
rules these out. Each one is an error at its line:

| PyShader | in OpenGL ES 2 |
|---|---|
| `while` | only `for` loops are guaranteed: write `for i in range(N):` with a `break` |
| `range(n)` with `n` computed at run time | loop bounds must be constants; loop to a constant maximum and `break` |
| assigning a loop counter, or reading it after the loop | the counter is constant in the body and exists only inside the loop |
| `xs[i]`, `v[i]` with `i` computed at run time | indices are constants and `for` counters, or expressions of them |
| `uint`, `short`, `ushort` | no unsigned or 16-bit integers |
| `&`, `\|`, `^`, `~`, `<<`, `>>` on integers | no bitwise operators (on bools they are `&&`, `\|\|`, `^^`) |
| `float2x3` and other non-square matrices | square matrices only |
| `transpose`, `determinant`, `inverse` | no matrix functions |
| `isnan`, `isinf`, `modf`, `frexp`, `ldexp`, packing, bit functions | not in GLSL ES 1.00 |
| fine and coarse derivatives | only `dFdx`, `dFdy`, `fwidth` |
| array arguments (`FloatArray`), class and list inputs | uniforms have a fixed size, and there are no storage buffers |
| `vertex_index`, `instance_index` | no `gl_VertexID`, no instancing |
| integer or bool varyings | only floats are interpolated |
| a function returning a list, a class or tuple holding one | arrays cannot be returned, nor structs holding them assigned |

Some things it lacks are written out instead, with the same results:

- `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh`, `trunc` and `round`
  become small helper functions. `round` rounds half to even, as Python
  does.
- `abs`, `sign`, `min`, `max`, `clamp`, `//` and `%` on integers go through
  floats, since GLSL ES 1.00 has them for floats only. They are exact for
  the integer range OpenGL ES 2 promises.
- `match` becomes an `if` chain, since there is no `switch`.
- A list literal fills a local array element by element, since there is no
  array constructor. A list is assigned element by element.
- `float3x3(m)` from another matrix is built column by column.

For example, a bitwise `&` stops the build at its line:

```text
glow.py:2: error: OpenGL ES 2 has no bitwise operators (`&`)
    k = int(uv.x * 8.0) & 3
```
