# Docs plugin

The previews on this site come from `mkdocs-pyshader`, an MkDocs plugin in
the repository's [mkdocs-pyshader/](https://github.com/NucleantUI/PyShader/tree/main/mkdocs-pyshader)
folder. It registers four code fences with
[pymdownx.superfences](https://facelessuser.github.io/pymdown-extensions/extensions/superfences/)
and ships the runtime: the compiler and decompiler as WebAssembly, naga as
WebAssembly, and a small WebGPU renderer.

## Fences

````md
```pyshader
def main(uv: float2) -> float4:
    return float4(uv, 0.0, 1.0)
```
````

| fence | renders |
|---|---|
| ```` ```pyshader ```` | the highlighted code, then the live preview under it |
| ```` ```pyshader-preview ```` | the preview only |
| ```` ```pyshader-edit ```` | a Monaco editor beside the preview, recompiling as you type |
| ```` ```pyshader-convert ```` | a GLSL editor beside the PyShader it decompiles to, as on [GLSL to PyShader](convert.md); the body is GLSL |

Options go on the fence line as `key="value"`:

| option | meaning |
|---|---|
| `file="Examples/plasma.py"` | take the source from a file (relative to `mkdocs.yml`) instead of the fence body |
| `examples="Examples/shadertoy/opengl"` | `pyshader-convert` only: a folder whose `.glsl` files fill a picker; the first one is the initial source when the body is empty |
| `args="gain:float=1.5, tint:float4=1 0.6 0.2 1, mins:floatArray=0.2 0.5"` | `ShaderArgument`s: name, kind and the values to pass |
| `content="img/card.png"` | the image `layer()` reads, relative to the site root; a test card when omitted |
| `target="graphics"` | compile a vertex + fragment module and draw it; default `compute` |
| `vertices="6" instances="3"` | the draw call for a graphics target |
| `height="360"` | the preview's height (the editor's, in `pyshader-edit`): pixels, or any CSS length such as `calc(100vh - 12rem)` |
| `aspect="16:9"` | size the preview by its width and this ratio instead of `height`; in `pyshader-edit` the toolbar offers 16:9, 4:3, 1:1 and fill |
| `layout="horizontal"` | `pyshader-edit` only: the initial layout — `horizontal` (editor and preview side by side), `vertical` (preview above the editor) or `auto` (default: by screen width). The block's toolbar lets the reader switch, and remembers the choice in the browser |
| `debounce="1000"` | `pyshader-edit` only: milliseconds of typing pause before a recompile (default 1000; 700 in `pyshader-convert`) |
| `title="…"` `linenums="1"` `hl_lines="2 3"` | passed to the code block |

## Setup

```yaml title="mkdocs.yml"
plugins:
  - search
  - pyshader
```

```sh
uv sync --group docs           # mkdocs-material and the plugin, editable
python3 scripts/build_wasm.py  # pyshader.wasm and naga.wasm into the plugin's assets
uv run mkdocs serve
```

The plugin adds `pymdownx.superfences` if missing, copies its assets to
`assets/pyshader/` in the site (with a content hash on their URLs, so a
deploy is not served from a browser's cache) and injects a
`window.PyShaderConfig` with the paths; `assets_dir`, `monaco_url` and
`glslang_url` are its settings.

## How a preview runs

1. `pyshader.wasm` — the Swift package `PyShaderWasm/` built as a WASI
   reactor with the wasm Swift SDK — compiles the source to SPIR-V for the
   compute target (or graphics, when asked), with `content=1` when the
   source calls `layer()` and the declared arguments.
2. `naga.wasm` — the Rust crate `NagaWasm/` — splits the combined image
   sampler `layer()` uses into a texture and a sampler (naga's SPIR-V
   frontend takes `OpSampledImage` but not a sampled-image global), then
   translates SPIR-V to WGSL.
3. WebGPU runs the compute shader over an `rgba8unorm` storage texture the
   size of the canvas and blits it, feeding `Uniforms` (time, frame,
   resolution, pointer) every frame; a graphics module is drawn straight
   into the canvas with alpha blending.

Both modules load once per page, lazily, when the first preview scrolls into
view. `pyshader.wasm` is around 13 MB (4.7 MB gzipped): Swift's Foundation
comes along, minus ICU's data tables, which the build stubs out.

A `pyshader-convert` block goes the other way. glslang, built to wasm by the
[@webgpu/glslang](https://www.npmjs.com/package/@webgpu/glslang) package and
fetched from `glslang_url`, compiles the GLSL (wrapped in NucleantVulkan's
fragment layout when it is a ShaderToy `mainImage`) to SPIR-V with debug
names, and `pyshader.wasm`'s `pyshader_decompile` export — the
`Spirv2PyShader` library — turns that into Python.

## Limits

WebGPU differs from Vulkan in a few places the compiler does not paper over:
no push constants (so no fragment target), no `isnan` / `isinf`, no 16-bit
integers, no derivatives in compute. A preview that hits one shows the
translation error in its frame. `half` works when the adapter offers
`shader-f16`.
