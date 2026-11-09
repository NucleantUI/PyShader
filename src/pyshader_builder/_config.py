"""Which shaders a project compiles: ``pyshader.toml``, or ``[tool.pyshader]``.

Both hold what the SwiftPM plugins read from ``pyshader.toml``: an optional
``site-packages`` for every section, and one table per shader::

    [tool.pyshader]
    site-packages = ".venv/lib/python3.13/site-packages"   # optional
    packages = ["src/myapp"]                                # optional, the wheel's packages

    [tool.pyshader.clouds]
    source = "src/myapp/shaders/clouds.py"
    output = "src/myapp/shaders/clouds"        # default: <section>.spv; gles2: <section>.vert + .frag
    target = "compute"                         # fragment (default) | compute | graphics
    format = "gles2"                           # spirv (default) | gles2
    single-file = true                         # gles2: both stages in one file (<section>.glsl)
    uv-top-down = true                         # gles2: the texture coordinates run top-down
    uv-varying = "v_uv"                        # gles2: the names the stages declare, and
    position-matrices = []                     #   how the vertex stage places its quad
    attributes = ["normal:float3"]             # gles2 graphics: more vertex attributes
    content = true                             # or content-top-down = true
    textures-top-down = true                   # the `Texture` parameters top-down; y-up by default
    arguments = ["gain:float", "tint:float4"]

Paths are relative to the project's root.
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass
from pathlib import Path

CONFIG_FILE = "pyshader.toml"
TARGETS = ("fragment", "compute", "graphics")
FORMATS = ("spirv", "gles2")
ARGUMENT_KINDS = ("float", "float2", "float3", "float4", "floatArray", "float2Array", "float3Array", "float4Array")
#: gles2 keys holding one name; each is the wasm option of the same name.
GLES2_NAME_KEYS = (
    "position-attribute", "texcoord-attribute", "color-attribute", "color-uniform",
    "opacity-uniform", "uv-varying", "color-varying", "content-sampler",
)
GLES2_KEYS = GLES2_NAME_KEYS + ("position-matrices", "single-file", "uv-top-down", "position-size", "attributes")
ATTRIBUTE_KINDS = ("float", "float2", "float3", "float4")
SECTION_KEYS = ("source", "output", "target", "content", "content-top-down", "textures-top-down", "arguments", "optimize", "format") + GLES2_KEYS


class ConfigError(Exception):
    """A mistake in the shader configuration, naming where it is."""


@dataclass(frozen=True)
class Section:
    name: str
    source: str
    output: str
    target: str = "fragment"
    format: str = "spirv"
    content: bool = False
    content_top_down: bool = False
    textures_top_down: bool = False
    arguments: tuple[str, ...] = ()
    #: gles2: both stages in one file rather than a ``.vert`` and a ``.frag``.
    single_file: bool = False
    #: gles2: the names and vertex-stage options given, as ``key=value`` compiler options.
    gles2_options: tuple[str, ...] = ()

    def outputs(self) -> tuple[str, ...]:
        """The files the section writes: ``output``, or for gles2 without
        ``single-file`` the ``.vert`` and ``.frag`` beside it, its extension replaced."""
        if self.format != "gles2" or self.single_file:
            return (self.output,)
        folder, _, name = self.output.replace("\\", "/").rpartition("/")
        stem = name.rsplit(".", 1)[0] if "." in name.lstrip(".") else name
        base = f"{folder}/{stem}" if folder else stem
        return (base + ".vert", base + ".frag")

    def options(self) -> str:
        """The compiler's options for this section (see PyShaderWasm's Exports.swift)."""
        parts = [f"target={self.target}", f"format={self.format}"]
        if self.content_top_down:
            parts.append("content-top-down=1")
        elif self.content:
            parts.append("content=1")
        if self.textures_top_down:
            parts.append("textures-top-down=1")
        parts += [f"arg={a}" for a in self.arguments]
        if self.single_file:
            parts.append("single-file=1")
        parts += self.gles2_options
        file = self.source.replace("\\", "/").rsplit("/", 1)[-1]
        if file and not any(c.isspace() for c in file):
            parts.append(f"file={file}")   # named in the output's header and line information
        return " ".join(parts)


@dataclass(frozen=True)
class Config:
    #: Where it was read from, for messages: ``pyshader.toml`` or ``pyproject.toml [tool.pyshader]``.
    origin: str
    sections: tuple[Section, ...]
    site_packages: str | None = None
    #: The wheel's package folders, when given.
    packages: tuple[str, ...] | None = None


def load(root: Path, pyproject: dict) -> Config | None:
    """The project's shader configuration; None when it has none."""
    in_pyproject = pyproject.get("tool", {}).get("pyshader")
    file = root / CONFIG_FILE
    if file.is_file():
        if in_pyproject is not None:
            raise ConfigError(f"both {CONFIG_FILE} and [tool.pyshader] in pyproject.toml configure shaders; keep one")
        try:
            table = tomllib.loads(file.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as error:
            raise ConfigError(f"{CONFIG_FILE}: {error}") from None
        return parse(table, CONFIG_FILE)
    if in_pyproject is None:
        return None
    return parse(in_pyproject, "pyproject.toml [tool.pyshader]")


def parse(table: dict, origin: str) -> Config:
    def fail(message: str) -> ConfigError:
        return ConfigError(f"{origin}: {message}")

    site_packages = None
    packages = None
    sections: list[Section] = []
    for key, value in table.items():
        if key == "site-packages":
            if not isinstance(value, str):
                raise fail("`site-packages` must be a string")
            site_packages = value
        elif key == "packages":
            if not isinstance(value, list) or not all(isinstance(p, str) for p in value):
                raise fail("`packages` must be an array of package folders, like [\"src/myapp\"]")
            packages = tuple(value)
        elif isinstance(value, dict):
            sections.append(_section(key, value, fail))
        else:
            raise fail(f"unknown key `{key}`; outside a section only `site-packages` and `packages` are set")
    if not sections:
        raise fail("no sections: add a table with a `source` for each shader")
    outputs = [o for s in sections for o in s.outputs()]
    for output in outputs:
        if outputs.count(output) > 1:
            raise fail(f"two sections write `{output}`")
    return Config(origin=origin, sections=tuple(sections), site_packages=site_packages, packages=packages)


def _section(name: str, table: dict, fail) -> Section:
    owner = f"[{name}] "
    for key in table:
        if key not in SECTION_KEYS:
            raise fail(f"{owner}unknown key `{key}`")

    def string(key: str, default: str | None = None) -> str | None:
        value = table.get(key, default)
        if value is not None and not isinstance(value, str):
            raise fail(f"{owner}`{key}` must be a string")
        return value

    def boolean(key: str) -> bool:
        value = table.get(key, False)
        if not isinstance(value, bool):
            raise fail(f"{owner}`{key}` must be `true` or `false`")
        return value

    source = string("source")
    if source is None:
        raise fail(f'{owner}needs `source = "path/to/shader.py"`')
    target = string("target") or "fragment"
    if target not in TARGETS:
        raise fail(f"{owner}`target` is one of {', '.join(TARGETS)}, not `{target}`")
    format = string("format") or "spirv"
    if format not in FORMATS:
        raise fail(f"{owner}`format` is one of {', '.join(FORMATS)}, not `{format}`")
    arguments = table.get("arguments", [])
    if not isinstance(arguments, list) or not all(isinstance(a, str) for a in arguments):
        raise fail(f'{owner}`arguments` must be an array of `"name:kind"`')
    for argument in arguments:
        parts = argument.split(":")
        if len(parts) != 2 or parts[1] not in ARGUMENT_KINDS:
            raise fail(f"{owner}argument `{argument}` must be `\"name:kind\"`, kind one of {', '.join(ARGUMENT_KINDS)}")
    if table.get("optimize"):
        raise fail(
            f"{owner}`optimize` runs spirv-opt, which the build backend does not have; "
            "compile with pyshaderc or the SwiftPM plugins to optimize"
        )
    content_top_down = boolean("content-top-down")
    if format != "gles2":
        for key in GLES2_KEYS:
            if key in table:
                raise fail(f'{owner}`{key}` applies to `format = "gles2"`')
    gles2_options: list[str] = []
    if boolean("uv-top-down"):
        gles2_options.append("uv-top-down=1")
    for key in GLES2_NAME_KEYS:
        value = string(key)
        if value is not None:
            if not value or any(c.isspace() or c == "=" for c in value):
                raise fail(f"{owner}`{key}` must be a GLSL name, not `{value}`")
            gles2_options.append(f"{key}={value}")
    matrices = table.get("position-matrices", [])
    if not isinstance(matrices, list) or not all(isinstance(m, str) and m and not any(c.isspace() or c == "=" for c in m) for m in matrices):
        raise fail(f"{owner}`position-matrices` must be an array of uniform names")
    gles2_options += [f"position-matrix={m}" for m in matrices]
    if "position-size" in table:
        size = table["position-size"]
        if isinstance(size, bool) or size not in (2, 3, 4):
            raise fail(f"{owner}`position-size` is 2, 3 or 4")
        gles2_options.append(f"position-size={size}")
    attributes = table.get("attributes", [])
    if not isinstance(attributes, list) or not all(isinstance(a, str) for a in attributes):
        raise fail(f'{owner}`attributes` must be an array of `"name:kind"`')
    for attribute in attributes:
        parts = attribute.split(":")
        if len(parts) != 2 or parts[1] not in ATTRIBUTE_KINDS or not parts[0] or any(c.isspace() or c == "=" for c in parts[0]):
            raise fail(f"{owner}attribute `{attribute}` must be `\"name:kind\"`, kind one of {', '.join(ATTRIBUTE_KINDS)}")
        gles2_options.append(f"attribute={attribute}")
    single_file = boolean("single-file")
    default_output = f"{name}.spv" if format == "spirv" else f"{name}.glsl" if single_file else name
    return Section(
        name=name,
        source=source,
        output=string("output") or default_output,
        target=target,
        format=format,
        content=boolean("content") or content_top_down,
        content_top_down=content_top_down,
        textures_top_down=boolean("textures-top-down"),
        arguments=tuple(arguments),
        single_file=single_file,
        gles2_options=tuple(gles2_options),
    )
