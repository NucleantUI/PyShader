# Examples

Every example in the repository's [Examples/](https://github.com/NucleantUI/PyShader/tree/main/Examples)
folder, compiled live. Each page shows the source and, at its end, the
result; move the pointer over the ones that read `mouse`.

<div class="grid cards" markdown>

-   **[Plasma](plasma.md)** — module constants, a palette helper, `uv` and `time`

    ```pyshader-preview file="Examples/plasma.py" height="180"
    ```

-   **[Control flow](control-flow.md)** — `if`/`elif`, `while`, `for range`, `break`, `continue`

    ```pyshader-preview file="Examples/control_flow.py" height="180"
    ```

-   **[Lambdas & types](lambdas-and-types.md)** — lambdas per argument type, `half`, `uint` hashing

    ```pyshader-preview file="Examples/NucleantSwiftUIExample/Sources/PyShaderSwiftUIExample/Resources/Shaders/06_lambdas.py" height="180"
    ```

-   **[Module style](module-style.md)** — the stub import, `pyshader.sin`, chained compares, indexing

    ```pyshader-preview file="Examples/module_style.py" height="180"
    ```

-   **[Arguments](arguments.md)** — `ShaderArgument`s by name, a `FloatArray`

    ```pyshader-preview file="Examples/compute/arguments.py" args="gain:float=1.5, tint:float4=1 0.6 0.2 1, mins:floatArray=0.2 0.5 0.9 0.4" height="180"
    ```

-   **[Effects](effects.md)** — `layer()` over a view: ripple, blur, CRT, chromatic, tint

    ```pyshader-preview file="Examples/compute/effect_ripple.py" height="180"
    ```

-   **[SwiftUI gallery](swiftui-gallery.md)** — the seven shaders of the NucleantSwiftUI example app

    ```pyshader-preview file="Examples/NucleantSwiftUIExample/Sources/PyShaderSwiftUIExample/Resources/Shaders/05_raymarch.py" height="180"
    ```

-   **[ShaderToy ports](shadertoy.md)** — four ShaderToy shaders, GLSL and PyShader side by side

    ```pyshader-preview file="Examples/shadertoy/pyshader/cyber-fuji-2020.py" height="180"
    ```

-   **[Instanced glow](graphics.md)** — the graphics target: a vertex + fragment module with varyings

    ```pyshader-preview file="Examples/graphics/instanced_glow.py" target="graphics" vertices="6" instances="3" args="touches:floatArray=0.3 0.5 0.1 0 0.7 0.4 0.6 0 0.5 0.75 0.9 0, glowSeconds:float=1000000" height="180"
    ```

</div>
