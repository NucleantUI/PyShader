# Plasma

Classic plasma: module-level constants (`PI`, `SPEED`) inlined where used, a
`palette` helper returning a `float3`, and `main` taking `uv`, `time` and
`resolution` by name.

```pyshader file="Examples/plasma.py"
```

The docstring on the first line says "push constants" because the file was
written for the [fragment target](../targets/fragment.md); the same source
compiles for the compute target — and this preview — unchanged, since it only
uses inputs both targets provide.
