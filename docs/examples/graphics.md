# Instanced glow

The [graphics target](../targets/graphics.md): one module with a `vertex`
and a `fragment` entry point, a `class` for the varyings, and a `FloatArray`
argument holding x, y, seed and start time per glow. NucleantSwiftUI's
`VertexShader` draws it with `vertices: 6, instances: touches.count` — one
quad per touch. It is the glow from the Kivy Baby Lights app.

```pyshader file="Examples/graphics/instanced_glow.py" target="graphics" vertices="6" instances="3" args="touches:floatArray=0.3 0.5 0.1 0 0.7 0.4 0.6 0 0.5 0.75 0.9 0, glowSeconds:float=1000000" height="360"
```

The preview draws three fixed glows with a very long `glowSeconds`, so they
never fade. In the app:

```swift
VertexShader(VertexShaderFunction(pyshader: source), vertices: 6, instances: touches.count, arguments: [
    .floatArray("touches", packedTouches),     // x, y, seed, started per glow
    .float("glowSeconds", 2.0),
])
```
