"""A PEP 517 build backend that compiles a project's PyShader shaders into its wheel.

In the project's ``pyproject.toml``::

    [build-system]
    requires = ["pyshader"]
    build-backend = "pyshader_builder"

    [tool.pyshader.glow]
    source = "src/myapp/shaders/glow.py"
    output = "src/myapp/shaders/glow"
    target = "compute"
    format = "gles2"          # OpenGL ES 2: glow.vert and glow.frag; "spirv" (default) for Vulkan

The shaders can also be listed in a ``pyshader.toml`` at the project's root,
the file the SwiftPM plugins read, with the same keys. Each one is compiled
when a wheel is built and lands in it at its ``output``, which must be inside
one of the wheel's packages. An editable install (``uv sync``, ``pip install
-e``) writes them into the source tree instead, beside the code that loads
them.

A shader that does not compile, or uses what its format cannot express
(OpenGL ES 2 has no ``while``, no unsigned or bitwise integers, no compute…),
stops the build with ``file:line: error: …`` and the line of code.

The compiler is PyShader's own, as WebAssembly (``pyshader.wasm``), run with
wasmtime, which the backend asks the build frontend for, along with the
project's ``dependencies``: a shader library listed there is installed where
the build runs, so the shaders can import it.
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path

from . import _compiler, _config, _dist, _modules

__all__ = [
    "build_editable",
    "build_sdist",
    "build_wheel",
    "get_requires_for_build_editable",
    "get_requires_for_build_sdist",
    "get_requires_for_build_wheel",
]

WASMTIME = "wasmtime>=25"


class ShaderBuildError(Exception):
    """A shader that stops the build, with where and why."""


# MARK: - PEP 517 / 660 hooks


def get_requires_for_build_wheel(config_settings=None) -> list[str]:
    return [WASMTIME, *_dependencies(Path.cwd())]


def get_requires_for_build_editable(config_settings=None) -> list[str]:
    return [WASMTIME, *_dependencies(Path.cwd())]


def get_requires_for_build_sdist(config_settings=None) -> list[str]:
    return []


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None) -> str:
    root = Path.cwd()
    project, config = _load(root)
    packages = project.packages(config.packages if config else None)
    compiled = compile_shaders(root, config) if config else {}
    placed = {_place(root, path, packages): data for path, data in compiled.items()}
    writer = _dist.WheelWriter(Path(wheel_directory), project)
    for package in packages:
        for file in _dist.Project.files(package):
            arcname = file.relative_to(package.parent).as_posix()
            if arcname not in placed:   # a stale copy from an editable install
                writer.add(arcname, file.read_bytes())
    for arcname, data in sorted(placed.items()):
        writer.add(arcname, data)
    return writer.close()


def build_editable(wheel_directory, config_settings=None, metadata_directory=None) -> str:
    root = Path.cwd()
    project, config = _load(root)
    packages = project.packages(config.packages if config else None)
    compiled = compile_shaders(root, config) if config else {}
    for path, data in compiled.items():
        _place(root, path, packages)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    writer = _dist.WheelWriter(Path(wheel_directory), project)
    folders = sorted({str(p.parent.resolve()) for p in packages})
    writer.add(f"__editable__.{project.dist}-{project.version}.pth", ("\n".join(folders) + "\n").encode())
    return writer.close()


def build_sdist(sdist_directory, config_settings=None) -> str:
    root = Path.cwd()
    project, config = _load(root)
    # The compiled shaders are build products: the sdist carries their sources.
    outputs = {(root / o).resolve() for s in config.sections for o in s.outputs()} if config else set()
    return _dist.write_sdist(Path(sdist_directory), project, outputs)


# MARK: - Compiling


def compile_shaders(root: Path, config: _config.Config) -> dict[Path, bytes]:
    """Every section of ``config`` compiled, by output path."""
    compiler = _compiler.Compiler()
    site = (root / config.site_packages) if config.site_packages else None
    out: dict[Path, bytes] = {}
    for section in config.sections:
        source = root / section.source
        if not source.is_file():
            raise ShaderBuildError(f"{config.origin} [{section.name}]: source `{section.source}` does not exist")
        text = source.read_text(encoding="utf-8")
        modules = _modules.collect(source, site)
        try:
            data, vertex = compiler.compile(text, section.options(), modules)
        except _compiler.CompileError as error:
            raise ShaderBuildError(_describe(error, section, config, text)) from None
        outputs = section.outputs()
        for output, stage in zip(outputs, (vertex, data) if len(outputs) == 2 else (data,)):
            out[(root / output).resolve()] = stage
        kind = "OpenGL ES 2" if section.format == "gles2" else "SPIR-V"
        print(f"pyshader: [{section.name}] {section.source} -> {', '.join(outputs)} ({kind})", file=sys.stderr)
    return out


def _describe(error: _compiler.CompileError, section: _config.Section, config: _config.Config, text: str) -> str:
    """``file:line: error: message``, the line of code under it, and the section it came from."""
    where = f"in [{section.name}] of {config.origin}, target = \"{section.target}\", format = \"{section.format}\""
    if error.line is None:
        return f"{section.source}: error: {error.message}\n  {where}"
    if error.file is not None:
        return f"{error.file}:{error.line}: error: {error.message}\n  imported by {section.source}, {where}"
    lines = text.splitlines()
    code = lines[error.line - 1].strip() if 0 < error.line <= len(lines) else ""
    excerpt = f"\n    {code}" if code else ""
    return f"{section.source}:{error.line}: error: {error.message}{excerpt}\n  {where}"


# MARK: - Helpers


def _dependencies(root: Path) -> list[str]:
    """The project's ``dependencies``, which the shaders' libraries are among:
    the build environment gets them too, so the shaders can import them."""
    file = root / "pyproject.toml"
    if not file.is_file():
        return []
    dependencies = tomllib.loads(file.read_text(encoding="utf-8")).get("project", {}).get("dependencies", [])
    return [d for d in dependencies if isinstance(d, str)]


def _load(root: Path) -> tuple[_dist.Project, _config.Config | None]:
    pyproject = tomllib.loads((root / "pyproject.toml").read_text(encoding="utf-8"))
    return _dist.Project(root, pyproject), _config.load(root, pyproject)


def _place(root: Path, path: Path, packages: list[Path]) -> str:
    """Where a compiled shader goes in the wheel: inside the package folder holding its output."""
    for package in packages:
        folder = package.resolve()
        if package.is_dir() and path.is_relative_to(folder):
            return path.relative_to(folder.parent).as_posix()
    names = ", ".join(str(p.relative_to(root)) for p in packages)
    raise ShaderBuildError(
        f"`{path.relative_to(root.resolve()) if path.is_relative_to(root.resolve()) else path}` is outside the wheel's "
        f"packages ({names}); put the section's `output` inside one, where the code that loads it is"
    )
