"""MkDocs plugin: PyShader code fences with a live WebGPU preview.

Three fences, registered with pymdownx.superfences by the plugin:

    ```pyshader            code block + preview
    ```pyshader-preview    preview only
    ```pyshader-edit       Monaco editor + preview, recompiled as you type

Fence options: file="path" (source from a file instead of the body, relative
to the mkdocs config directory), args="name:kind=value,..." (ShaderArguments),
content="image.png" (a `layer()` content image), height=NNN, target=compute|graphics,
vertices=N instances=N (graphics target draw call).
"""

__all__ = ["PyShaderPlugin"]

from .plugin import PyShaderPlugin
