# Lambdas & types

Lambdas bound at module level are instantiated once per distinct argument
type: `sq` below runs on a `float` and on a `float2`.

```pyshader file="Examples/NucleantSwiftUIExample/Sources/PyShaderSwiftUIExample/Resources/Shaders/06_lambdas.py"
```

## Half and integer math

16-bit float math, integer hashing with `uint`, and vector comparisons
reduced with `any()` / `all()`:

```pyshader file="Examples/NucleantSwiftUIExample/Sources/PyShaderSwiftUIExample/Resources/Shaders/07_halfmath.py"
```

!!! note
    `half` needs the `shaderFloat16` device feature on Vulkan and
    `shader-f16` on WebGPU; the preview requests it when the adapter has it.

## Everything at once

The repository's `lambdas_and_types.py` also exercises `short`, tuple
unpacking, ternaries and Python's `//`, `%` and `**`. It compiles and
validates as SPIR-V, but WebGPU has no 16-bit integers, so it is shown
without a preview:

```py title="Examples/lambdas_and_types.py"
--8<-- "Examples/lambdas_and_types.py"
```
