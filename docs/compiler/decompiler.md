# Decompiling SPIR-V

`Spirv2PyShader` turns a SPIR-V fragment stage back into PyShader source.
Its main use is porting: compile a GLSL shader with `glslangValidator`
against the same pipeline layout, decompile it, and tidy up the result
instead of translating by hand.

```sh
swift run spirv2py shader.spv -o shader.py
swift run spirv2py shader.spv --rename iTime=time --rename iResolution=resolution
```

For ShaderToy code there is no need for the tools: the
[GLSL to PyShader](../convert.md) page runs glslang and the decompiler in
the browser. It compiles the `mainImage` against `FragmentInterface.shaderToy`
(`ShaderToy.wrap(glsl)` gives the same GLSL; `spirv2py --shadertoy` reads
the result), whose names are the compute target's — `frag_coord` as a
`float2`, `resolution`, `time`, `time_delta`, `frame`, `mouse`,
`mouse_click` — so the PyShader runs as a NucleantSwiftUI `Shader` as it is.

```swift
import Spirv2PyShader

let py = try Spirv2PyShader.decompile(words)                        // [UInt32]
let py = try Spirv2PyShader.decompile(data, interface: .nucleant)   // a .spv file
py.source      // PyShader
py.warnings    // constructs without an exact PyShader spelling
py.entryPoint  // "main"
```

## What comes back

Interface variables are named through the `FragmentInterface`, the same
table the compiler uses, so a module compiled against NucleantVulkan's
layout reads like a shader written for it:

| SPIR-V | PyShader |
|---|---|
| `Input` at location 0 / 1 | `uv` / `color` |
| `BuiltIn FragCoord` / `FrontFacing` | `frag_coord` / `front_facing` |
| push constant at offset 0 / 8 / 16 | `time` / `resolution` / `mouse` |
| `Output` at location 0 | the value `main` returns |
| anything else | its SPIR-V name (a warning), or the `--rename` / `DecompileOptions.renames` one |

The body is rewritten into the shape the hand ports have:

- GLSL `out` / `inout` parameters become extra return values:
  `void trace(vec3 ro, out Hit h)` is `def trace(ro: float3, h: Hit) -> Hit`,
  and the call `trace(p, h)` is `h = trace(p, Hit(0.0, float3(0.0)))`.
- Uniforms a helper reads are threaded in as trailing parameters
  (`def dTile(p: float2, time: float)`), since PyShader has no globals.
- `for (int i = 0; i < n; ++i)` is `for i in range(n)`; other loops are
  `while`, with `break` / `continue`.
- `a && b` and `a || b` are `a and b` / `a or b`; `c ? x : y` is
  `x if c else y`; `col.rgb *= s` is `col.xyz *= s`.
- Structs become `class`es; array literals lists; matrices `floatCxR(...)`
  of column vectors.
- GLSL.std.450 instructions get their PyShader builtin names
  (`InverseSqrt` -> `rsqrt`, `FClamp(x, 0, 1)` -> `saturate(x)`).

The compiler's own output round-trips: `main` comes back as `main` with the
interface's parameter names, and helpers, tuple returns, lists and lambdas
(as their instantiated functions) as written.

## Limits

- Fragment stages only; a compute or vertex module is refused.
- Textures (`OpImageSample*`) and module-level (`Private`) variables have
  no PyShader equivalent and are reported. `switch` becomes an `if`/`elif`
  chain.
- `OpSDiv` is written as `//` and `OpSRem` as `%`; they differ from Python's
  floored semantics for negative operands (glslang's `%` is `OpSMod`, which
  matches).
- Unoptimised SPIR-V (glslang's default, and what PyShader emits) gives the
  cleanest source: locals are variables with a load at every use. Optimised
  modules decompile too, with more `_tN` temporaries, except where
  `spirv-opt`'s merge-return pass makes an early `return` jump out through
  more than one construct at once; that is reported.

## How it works

`SpirvCore` reads the word stream; `ModuleIndex` turns types into
`ShaderType`s and splits functions into blocks. `ModuleAnalysis` decides
the module-wide things: which functions the entry point reaches, which
pointer parameters are read back by a caller (out parameters), which
interface values each function reads through its callees. Then
`FunctionDecompiler` walks each function's structured control flow — a
selection merge is an `if`, a loop merge a `while` with its continue block
kept aside — building expression trees for SSA values and inlining each at
its single use. A store first pins any pending expression that reads the
stored variable into a temporary, placed before the `if`/`while` the store
sits in. `Peepholes` then lifts `while True: if not c: break` to
`while c:`, recognises counting loops, folds phi temporaries into `and` /
`or`, propagates single-use copies, and declares variables read before
assignment.
