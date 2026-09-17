# Arguments

Values handed in from Swift as `ShaderArgument`s become parameters of `main`
by name. Scalars and vectors arrive as `float` … `float4`; a `.floatArray`
arrives as a `FloatArray` that supports `a[i]` and `len(a)`.

```pyshader file="Examples/compute/arguments.py" args="gain:float=1.5, tint:float4=1 0.6 0.2 1, mins:floatArray=0.2 0.5 0.9 0.4"
```

The preview passes `gain = 1.5`, `tint = (1, 0.6, 0.2, 1)` and
`mins = [0.2, 0.5, 0.9, 0.4]`. In Swift:

```swift
Shader(ShaderFunction(pyshader: source), arguments: [
    .float("gain", 1.5),
    .color("tint", Color(red: 1.0, green: 0.6, blue: 0.2)),
    .floatArray("mins", [0.2, 0.5, 0.9, 0.4]),
])
```

## Tint effect

An effect that takes its colour and strength as arguments:

```pyshader file="Examples/NucleantSwiftUIExample/Sources/PyShaderSwiftUIExample/Resources/Effects/08_tint.py" args="tint:float4=1 0.5 0 1, strength:float=0.45"
```
