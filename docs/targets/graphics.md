# Graphics target

`.graphics(GraphicsInterface)` — `.nucleantSwiftUIGraphics` — compiles one
module with two entry points for NucleantVulkan's `VertFragShaderNode`, as
NucleantSwiftUI's `VertexShader` view drives it. `CompiledShader.entryPoint`
names the fragment stage, `vertexEntryPoint` the vertex stage.

`vertex` returns a `class` whose first field is the `float4` position
(y-up clip space, as in OpenGL — the wrapper flips it for Vulkan); every
other field is a varying, which `fragment` takes by name like any other input.

```py
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

## Inputs

There are no vertex buffers. The vertex stage has `vertex_index` and
`instance_index` besides the uniforms and the arguments; the fragment stage
has `uv`, `frag_coord`, `pixel` and `front_facing` besides those. A varying
may shadow a built-in input (`uv` for a quad's own coordinate is common),
but not an argument.

| parameter | vertex | fragment |
|---|---|---|
| `vertex_index` `instance_index` (`int`) | ✓ | |
| `time` `time_delta` `frame` `resolution` `mouse` `mouse_click` | ✓ | ✓ |
| *arguments* | ✓ | ✓ |
| `uv` `frag_coord` `pixel` `front_facing` | | ✓ |
| varyings, by name | | ✓ |

Bindings match the compute target: `Uniforms` at set 0 binding 1, the
argument buffer at binding 3.

## In Swift

```swift
let touches: [(name: String, kind: ShaderArgumentKind)] = [("touches", .floatArray), ("glowSeconds", .float)]
let shader = try PyShader.compile(source, target: .graphics(.nucleantSwiftUI(arguments: touches)))
// shader.vertexEntryPoint == "vertex", shader.entryPoint == "fragment"
```

```swift
VertexShader(VertexShaderFunction(pyshader: source), vertices: 6, instances: touches.count, arguments: [
    .floatArray("touches", values), .float("glowSeconds", 2.0),
])
```

The [Instanced glow](../examples/graphics.md) example is the whole module,
drawn live. A module with both stages needs nothing said about it: the docs'
previews and the [Playground](../playground.md) compile it as a graphics
target on sight, draw the vertices its `vertex_index` list holds, and take
its arguments from what the two stages ask for. What no source can say — how
many instances to draw, and what the arguments hold — the Playground's
toolbar asks for.
