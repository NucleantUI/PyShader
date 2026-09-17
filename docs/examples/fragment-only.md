# Builtins & forwarding

Two examples written for the [fragment target](../targets/fragment.md) that
the previews cannot run: WebGPU has no push constants, no `isnan`, and no
vertex colour input.

## Every builtin

Touches every builtin so the [Builtins](../language/builtins.md) table stays
honest; it takes `frag_coord` as a `float4`, as the fragment target provides it.

```py title="Examples/builtins.py"
--8<-- "Examples/builtins.py"
```

## Forwarding the colour

`main` with no return value forwards the `color` input unchanged.

```py title="Examples/forward_color.py"
--8<-- "Examples/forward_color.py"
```

Both compile with `swift run pyshaderc Examples/<name>.py` and validate with
`spirv-val --target-env vulkan1.0`.
