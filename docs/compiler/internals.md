# How it works

Python source is parsed with [PySwiftAST](https://github.com/Py-Swift/PySwiftAST)
into a CPython-shaped AST. The compiler is four folders of Swift:

| folder | job |
|---|---|
| `Frontend/` | validates the module and collects definitions: functions, lambdas, constants, classes, the entry points a target wants |
| `Codegen/` | lowers statements and expressions to SPIR-V, one `FunctionEmitter` per function, and generates the target's wrapper around `main` |
| `Builtins/` | the function table — every builtin with its argument rules, promotion and the `GLSL.std.450` or core op it becomes |
| `SPIR-V/` | encodes words: types, constants, decorations, instructions, the module layout |

## Lowering

- Every local is an `OpVariable` in the function's first block, loaded and
  stored at every use. There is no SSA construction; drivers do that, and
  `spirv-opt -O` does it offline if wanted.
- A variable's type is fixed on first assignment or by annotation; literal
  conversions fold into constants, and constructors of literals into
  `OpConstantComposite`.
- Control flow is structured: `if` is `OpSelectionMerge` +
  `OpBranchConditional`; loops are `OpLoopMerge` with header, body and
  continue blocks; `break` / `continue` / early `return` branch out.
- Functions become `OpFunction`s; tuples are `OpTypeStruct`s; lists are
  `OpTypeArray`s; classes are structs. Lambdas are instantiated per
  argument-type signature at the call site. Module constants are inlined.
- Types are created on demand: `half` adds the `Float16` capability, `short`
  / `ushort` add `Int16`, `layer()` adds `ImageQuery` for `imageSize`.
- The wrapper is the only target-specific code: it declares the inputs
  (locations, built-ins, push constants or the `Uniforms` block), calls
  `main` with what it asked for by name and writes the result.

The output is SPIR-V 1.0 for `vulkan1.0`, validated with `spirv-val` in the
tests.

## Tests

```sh
swift test                      # every example through spirv-val, plus codegen and error tests
./scripts/validate_examples.sh  # the examples through pyshaderc and spirv-val
```

## Docs and the browser build

The previews on this site run the same compiler in WebAssembly. `scripts/build_wasm.py`
builds `PyShaderWasm/` (a Swift package exporting `pyshader_compile` and
friends) with the wasm Swift SDK, and `NagaWasm/` (a Rust crate wrapping
[naga](https://github.com/gfx-rs/wgpu/tree/trunk/naga)'s SPIR-V frontend and
WGSL backend). See [Docs plugin](../plugin.md).
