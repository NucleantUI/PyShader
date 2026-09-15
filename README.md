# PyShader

Write fragment shaders in Python syntax, get SPIR-V bytecode. No GLSL, no
shaderc: the compiler parses Python with
[PySwiftAST](https://github.com/Py-Swift/PySwiftAST) and emits SPIR-V 1.0
words directly.

```py
def main(uv: float2, time: float) -> float4:
    color = float4(1, 0, 0, 1)
    color.rgb *= 0.5
    color.rgb = color.rgb + 0.5
    color.r = color.r / 2
    return color
```

```swift
import PyShader

let shader = try PyShader.compile(source)                        // fragment, NucleantVulkan VKShader layout
let compute = try PyShader.compile(source, target: .nucleantSwiftUI)   // compute, NucleantSwiftUI Shader layout
shader.spirv        // [UInt32] for vkCreateShaderModule
shader.entryPoint   // "main"
```

## Targets

The Python is the same for both; only the generated wrapper around `main` differs.

| `ShaderTarget` | Stage | Matches | `main` inputs |
|---|---|---|---|
| `.fragment(FragmentInterface)` — default `.nucleant` | Fragment | NucleantVulkan `NucleantShader` / `VKShader`: `vTexCoord` in, `fragColor` out, push constants `{time, resolution, mouse}` | `uv`, `color`, `frag_coord`, `front_facing`, `time`, `resolution`, `mouse` |
| `.computeImage(ComputeImageInterface)` — `.nucleantSwiftUI` | GLCompute 8×8 | NucleantVulkan `OGLShaderNode` as NucleantSwiftUI's `Shader` / `.shader(_:)` drive it: storage image @0, `Uniforms` @1, content `sampler2D` @2, argument buffer @3 | `uv`, `frag_coord`, `pixel`, `time`, `time_delta`, `frame`, `resolution`, `mouse`, `mouse_click`, every `ShaderArgument` by name; `layer(uv)` reads the view |

Bindings, local size and argument declarations are properties of the interface
structs, so a variant pipeline adjusts them rather than the compiler.

## In NucleantSwiftUI

NucleantSwiftUI depends on this package; `ShaderFunction(pyshader:)` is the
Python counterpart of the GLSL initialisers and goes everywhere a
`ShaderFunction` goes — `Shader(...)`, `.shader(_:)`, `arguments:`:

```swift
let plasma = ShaderFunction(pyshader: """
    def main(uv: float2, time: float) -> float4:
        v = sin(uv.x * 10.0 + time) + sin((uv.y * 10.0 + time) * 0.5)
        return float4(float3(0.5 + 0.5 * sin(3.14159 * v)), 1.0)
""")

Shader(plasma)
someView.shader(ShaderFunction(pyshader: "def main(uv: float2) -> float4:\n    return layer(uv)"))
```

Source in a Swift multi-line literal is dedented by the compiler, so it can be
indented with the surrounding code.

[Examples/NucleantSwiftUIExample](Examples/NucleantSwiftUIExample) is a
runnable app in the shape of NucleantSwiftUI's demo — a "Shaders" gallery of
`Shader` views and an "Effects" gallery of `.shader(_:)` effects over a card,
live thumbnails, each opening full screen. Every entry is a `.py` file under
`Resources/Shaders` or `Resources/Effects` starting with
`from pyshader import *`, loaded as a string at runtime; its docstring is the
name and blurb. Separate package, so NucleantSwiftUI's own demo is untouched:

```sh
cd Examples/NucleantSwiftUIExample && swift run
PYSHADER_EXAMPLE_START=effects swift run     # open a gallery directly
```

## Editor support

The repo is also the `pyshader` Python package ([pyproject.toml](pyproject.toml),
[src/pyshader/](src/pyshader/)): every type and builtin as typed stubs (`...`
bodies) — the API as the IDE sees it, generated from the same list the
compiler implements. `from pyshader import *` at the top of a shader file
gives completion and type errors; the compiler ignores the import.

```sh
uv pip install -e .            # or: uv add --editable path/to/PyShader
uv run scripts/generate_stub.py   # regenerate after changing the API
```

## Layout

```
Sources/PyShader
├── PyShader.swift              public API: PyShader.compile(_:interface:)
├── Interface/ShaderTarget       fragment vs compute-into-image; ComputeImageInterface (NucleantSwiftUI)
├── Interface/FragmentInterface  the fragment stage's inputs / push constants / output
├── Frontend/ShaderProgram       validates the module scope, collects defs / constants / lambdas
├── Codegen/ShaderCompiler       drives emission, entry-point wrapper, lambda instantiation
├── Codegen/FunctionEmitter      statements, structured control flow, locals, lvalues
├── Codegen/ExpressionEmitter    expressions, promotion rules, swizzles, constructors
├── Builtins/BuiltinFunctions    GLSL.std.450 + core ops table
├── Types/ShaderType             the type model
└── SPIRV/                       opcodes, instruction encoding, module builder (ids, dedup, layout)
Sources/pyshaderc                CLI: pyshaderc in.py [-o out.spv] [--target compute --content --arg name:kind]
Examples/                        feature-coverage shaders, also used by the tests
Examples/compute/                shaders for the compute target (layer(), FloatArray)
Examples/NucleantSwiftUIExample  stand-alone app: PyShader inside NucleantSwiftUI
src/pyshader/                    the `pyshader` Python package (generated stubs)
scripts/generate_stub.py         regenerates it
```

Docs: [vector-types.md](vector-types.md) (types, constructors, promotion,
operator semantics) and [shader-api-status.md](shader-api-status.md)
(builtins implemented vs. to do, entry-point interface).

## Rules of the language

- Only global `def` functions, module-level constants, and lambdas bound to a
  name. No classes, no imports (except the ignored `pyshader` stub), no
  `*args` / `**kwargs`, no keyword arguments at call sites.
- Parameters need type annotations (`x: float3`); locals get their type from
  the first assignment or an annotation.
- `main` parameters are looked up by name in the interface; the order is free.
- Control flow: `if` / `elif` / `else`, `while`, `for ... in range(...)`,
  `break`, `continue`, `return`. Every path of a non-`None` function must
  return.
- Recursion is rejected (SPIR-V forbids it).
- Errors carry the Python line: `line 3: cannot implicitly convert `float` to `int`; use int(...)`.

## Development

```sh
swift test                         # 37 tests; runs spirv-val on every example when installed
./scripts/validate_examples.sh     # compile Examples/*.py and validate each .spv
swift run pyshaderc Examples/plasma.py -o plasma.spv && spirv-dis plasma.spv
```

`spirv-val`, `spirv-dis` and `spirv-opt` come with SPIRV-Tools / the Vulkan
SDK. When optimizing offline use `spirv-opt --target-env=vulkan1.0`; with a
newer env the optimizer folds into SPIR-V 1.4 forms the 1.0 module cannot
express.

## Codegen notes

- Locals are `OpVariable`s in the entry block with `OpLoad` / `OpStore` at
  every use; no SSA construction. `spirv-opt -O` reduces the plan example from
  382 words to 88.
- Structured control flow: `OpSelectionMerge` for `if`, `OpLoopMerge` with a
  separate condition block and continue block for loops. Code after
  `return` / `break` / `continue` lands in an unreachable block that ends in
  `OpUnreachable` or a branch, so blocks always have one terminator.
- Types and constants are deduplicated by value; literal conversions
  (`float4(1, 0, 0, 1)`, `-1.0`, `v + 0.5`) fold into constants.
- Lambdas are monomorphized: `sq(uv.x)` and `sq(uv)` become two functions.
- 16-bit types add the `Float16` / `Int16` capabilities on demand.
