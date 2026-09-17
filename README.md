# PyShader

Shaders in Python syntax, compiled straight to SPIR-V. No GLSL in between.

```py
from pyshader import *

def main(uv: float2, time: float) -> float4:
    color = float4(1, 0, 0, 1)
    color.rgb *= 0.5 + 0.5 * sin(time)
    color.r = color.r / 2
    return color
```

`main` runs once per pixel and returns its colour. It takes what it needs by
parameter name — `uv`, `frag_coord`, `time`, `resolution`, `mouse`, … — and
the compiler wires those up. `from pyshader import *` is for the editor
(completion, type errors); the compiler ignores it.

## The language

### Types

Metal's spelling: `float`, `half`, `int`, `uint`, `short`, `ushort`, `bool`,
each as `float2` `float3` `float4` … and matrices `float2x2` … `float4x4`.
Type names are constructors.

```py
a = float4(1, 0, 0, 1)      # ints convert
b = float3(uv, 1.0)         # vector + scalar flatten in order
c = float2(0.5)             # splat
d = float3(a)               # truncate
i = int(uv.x * 10.0)        # explicit conversion; float -> int is never implicit
h = half3(b)                # 16-bit
m = float3x3(c0, c1, c2)    # columns; float3x3() is identity, float3x3(2.0) diagonal
```

A variable's type is fixed by its first assignment, or by an annotation:

```py
n: float3                   # declared, assigned later
k: float = 2                # 2 becomes 2.0
```

### Swizzles

`.xyzw` and `.rgba`, read or write, 1 to 4 letters.

```py
p = uv.yx
color.rgb *= 0.5
color.a = 1.0
v[0] = 1.0                  # indexing works too, negative indices wrap
x, y = uv                   # unpack
```

### Operators — Python semantics

```py
7 / 2        # 3.5, always true division
-7 // 2      # -4, floored
-7 % 3       # 2, sign of the divisor
2 ** 3       # 8.0
v * 2.0      # scalars broadcast against vectors
m * v        # matrix * vector; v * m; m * m; m @ v is the same
a @ b        # on two vectors: dot product
uv > 0.5     # component-wise -> bool2; any() / all() to reduce
x if c else y
a < b < c    # chained
h ^ (h >> 13)  # bit ops on ints
```

`int + float -> float`, `half + float -> float`, an int literal next to a
`uint` becomes `uint`. Mixed vector sizes are an error.

### Functions

Global `def`s with annotated parameters. Several results come back as a tuple.

```py
def palette(t: float) -> float3:
    return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)))

def box(ro: float3, rd: float3) -> tuple[float, float3]:
    ...
    return t, normal

t, n = box(ro, rd)
```

Lambdas bound at module level are instantiated per argument type:

```py
sq = lambda x: x * x
sq(uv.x)    # float
sq(uv)      # float2
```

Module-level constants are inlined where used:

```py
PI = 3.14159265
RED = float3(1.0, 0.0, 0.0)
NO_HIT = (False, -1.0, float3(0.0))
```

No recursion (SPIR-V forbids it), no classes, no imports besides `pyshader`,
no keyword arguments.

### Control flow

```py
if d < 0.001:
    hit = True
elif d > 20.0:
    break
else:
    t += d

for i in range(64):         # ints; range(start, stop, step) too
    ...
while x >= 0.0:             # float-stepped loops
    x -= 6.67
```

`break`, `continue`, early `return` anywhere. Every path of a non-`None`
function must return.

### Lists

Fixed-size arrays from list literals.

```py
colors = [float4(0.0)] * 3
w: list[float] = [0.13, 0.07, 0.03]
colors[i] = float4(w[i])
colors[i].rgb *= 0.5
colors[0], colors[1] = colors[1], colors[0]
len(w)
```

### Builtins

GLSL 450 names, Metal spellings accepted; ints promote, scalars broadcast:

`sin cos tan asin acos atan atan2 sinh cosh tanh radians degrees` ·
`pow exp exp2 log log2 sqrt rsqrt` ·
`abs sign floor ceil round trunc fract mod min max clamp saturate mix lerp step smoothstep fma isnan isinf` ·
`length distance dot cross normalize reflect refract faceforward` ·
`transpose determinant inverse` · `any all` ·
`dfdx dfdy fwidth discard` (fragment stage only) ·
`layer(uv)` (the view under a `.shader` effect) · `len`

The full table, with what is still to do, is in [shader-api-status.md](shader-api-status.md).
Types, promotion and operator rules in detail: [vector-types.md](vector-types.md).

### Entry point inputs

| parameter | type | fragment target | compute target (NucleantSwiftUI) |
|---|---|---|---|
| `uv` | `float2` | `vTexCoord` | `frag_coord / resolution`, y-up |
| `frag_coord` | `float2`/`float4` | `gl_FragCoord` | pixel centre, y-up |
| `time` `resolution` `mouse` | | push constants | `Uniforms` block |
| `time_delta` `frame` `pixel` `mouse_click` | | — | `Uniforms` / invocation id |
| `color` | `float4` | vertex colour, forwarded by a bare `return` | — |
| *ShaderArgument name* | `float`…`float4`, `FloatArray` | — | argument buffer |

### Vertex + fragment

The graphics target compiles one module with two entry points. `vertex`
returns a `class` whose first field is the `float4` position (y-up clip
space, as in OpenGL — the wrapper flips it for Vulkan); every other field is
a varying, which `fragment` takes by name like any other input:

```python
class Glow:
    position: float4
    local: float2
    seed: float

def vertex(vertex_index: int, instance_index: int, touches: FloatArray) -> Glow:
    t = instance_index * 3
    corner = QUAD[vertex_index]
    return Glow(float4(float2(touches[t], touches[t + 1]) + corner * 0.25, 0.0, 1.0),
                local=corner * 0.5 + 0.5, seed=touches[t + 2])

def fragment(local: float2, seed: float, time: float) -> float4:
    return float4(float3(mod(seed + time, 1.0)), smoothstep(0.5, 0.0, distance(local, float2(0.5))))
```

There are no vertex buffers: `vertex_index` and `instance_index` are the
only vertex-stage inputs besides the uniforms (`time`, `time_delta`,
`frame`, `resolution`, `mouse`, `mouse_click`) and the arguments, which both
stages may take. The fragment stage has `uv`, `frag_coord`, `pixel` and
`front_facing` besides. A varying may shadow a built-in input (`uv` for a
quad's own coordinate is common), but not an argument. Classes are plain
structs — annotated fields only, constructed positionally or by keyword,
read with `v.field` — and work anywhere, not just as varyings.

## Examples

- [Examples/](Examples/) — one file per feature, all validated with `spirv-val` in the tests.
- [Examples/graphics/](Examples/graphics/) — a vertex + fragment module: Baby Lights' instanced glows.
- [Examples/shadertoy/](Examples/shadertoy/) — four ShaderToy shaders in GLSL
  and PyShader side by side, plus an app that runs each pair next to each
  other. [Its README](Examples/shadertoy/README.md) lists what porting needed.
- [Examples/NucleantSwiftUIExample/](Examples/NucleantSwiftUIExample/) — a
  gallery of `.py` shaders and `.py` effects in a NucleantSwiftUI window.
- [Examples/liquid_glass/](Examples/liquid_glass/) — a home screen whose
  app icons are liquid glass, each its own `.shader` effect.

## Editor

The repo is the `pyshader` Python package ([src/pyshader/](src/pyshader/)):
typed stubs for every type and builtin, generated from the same list the
compiler implements.

```sh
uv pip install -e .               # or: uv add --editable path/to/PyShader
uv run scripts/generate_stub.py   # regenerate after changing the API
```

## Compiling

```swift
import PyShader

let shader = try PyShader.compile(source)                             // fragment, NucleantVulkan VKShader layout
let compute = try PyShader.compile(source, target: .nucleantSwiftUI)  // compute, NucleantSwiftUI Shader layout
shader.spirv        // [UInt32] for vkCreateShaderModule
```

Or from the command line:

```sh
swift run pyshaderc shader.py -o shader.spv [--target compute --content --arg name:float4]
```

Three targets, same Python: `.fragment(FragmentInterface)` for a fragment stage
(default: NucleantVulkan's `NucleantShader` layout), `.computeImage(ComputeImageInterface)`
for a compute stage writing a storage image (NucleantVulkan's `OGLShaderNode`,
as NucleantSwiftUI drives it), and `.graphics(GraphicsInterface)` for a
vertex + fragment pair in one module (NucleantVulkan's `VertFragShaderNode`);
`CompiledShader.vertexEntryPoint` names the second entry point. Bindings and
argument declarations are properties of the interface structs.

In NucleantSwiftUI, `ShaderFunction(pyshader: source)` goes wherever a
`ShaderFunction` goes — `Shader(...)`, `.shader(_:)`, `arguments:` — and
`VertexShaderFunction(pyshader: source)` into a `VertexShader(...)`.

## Decompiling

`Spirv2PyShader` goes the other way: a SPIR-V fragment stage back to
PyShader source. It is how a GLSL shader becomes a PyShader one without
porting it by hand — compile the GLSL with `glslangValidator` against the
same interface, decompile, tidy up. For ShaderToy code the docs do it in
the browser: [GLSL to PyShader](https://nucleantui.github.io/PyShader/convert/).

```sh
swift run spirv2py shader.spv -o shader.py [--rename iTime=time]...
swift run spirv2py shader.spv --shadertoy   # compiled with ShaderToy.wrap: the compute target's names
```

```swift
import Spirv2PyShader

let py = try Spirv2PyShader.decompile(words)          // or a .spv file's Data
py.source                                             // PyShader
py.warnings                                           // constructs with no exact PyShader spelling
```

Interface variables are named through the `FragmentInterface` (default
`.nucleant`, like the compiler): `gl_FragCoord` is `frag_coord`, the push
constant at offset 0 is `time`, and so on; anything the interface does not
describe keeps its SPIR-V name, with a warning, or takes the `--rename` one.
GLSL `out` parameters become tuple returns, uniforms read inside helpers are
threaded in as parameters, `for (int i = 0; i < n; ++i)` comes back as
`for i in range(n)`, `a && b` as `a and b` — the shape the hand ports in
[Examples/shadertoy/pyshader/](Examples/shadertoy/pyshader/) have. The tests
send every ShaderToy example through glslang, the decompiler and the compiler.

Only fragment stages are handled; textures and module-level (`Private`)
variables are reported rather than translated.

## Documentation

The docs site (MkDocs + Material) lives in [docs/](docs/) and runs every
example live in the browser: the compiler built to WebAssembly compiles the
page's Python to SPIR-V, naga turns it into WGSL, WebGPU draws it. The
[mkdocs-pyshader](mkdocs-pyshader/) plugin provides the `pyshader`,
`pyshader-preview` and `pyshader-edit` (Monaco) fences.

```sh
uv sync --group docs            # mkdocs-material + the plugin
python3 scripts/build_wasm.py   # PyShaderWasm/ (wasm Swift SDK) and NagaWasm/ (Rust) -> plugin assets
node scripts/check_docs.mjs     # every snippet in docs/ through both wasm modules
uv run mkdocs serve
```

## Development

```sh
swift test                          # every example through spirv-val; ShaderToy GLSL through glslang and back
./scripts/validate_examples.sh
```

Targets: `SpirvCore` is the SPIR-V opcode and enum tables, the instruction
encoding and a word-stream reader, shared by both directions; `PyShader` is
the compiler; `Spirv2PyShader` the decompiler; `pyshaderc` and `spirv2py`
their command lines.

Compiler sources: `Frontend/` validates the module and collects definitions,
`Codegen/` lowers statements and expressions, `Builtins/` is the function
table, `SPIRV/` assembles the module. Locals are `OpVariable`s with load/store at
every use (no SSA construction); control flow is `OpSelectionMerge` /
`OpLoopMerge`; literal conversions fold into constants; 16-bit types add the
`Float16` / `Int16` capabilities on demand. Offline optimisation:
`spirv-opt --target-env=vulkan1.0 -O`.
