"""The PyShader modules a shader may import, read into memory for the compiler.

The compiler runs as wasm without a file system, so its imports are handed
over as sources by dotted name, from the same places ``pyshaderc`` looks:

1. the ``.py`` files beside the shader and below its folder;
2. the ``site-packages`` the configuration names, or else the one of the
   nearest ``.venv`` above the shader (or of ``VIRTUAL_ENV``);
3. the build environment itself (a shader library listed in
   ``[build-system] requires``).

From a site-packages folder only the packages a distribution declares under
the ``pyshader.modules`` entry point are taken, editable installs (``.pth``)
included. ``pyshader`` itself is the compiler's builtin, never read.
"""

from __future__ import annotations

import importlib.metadata
import os
from pathlib import Path

SKIPPED_FOLDERS = {"__pycache__", ".venv", "venv", ".git", "build", "dist", ".build"}


def collect(source: Path, site_packages: Path | None) -> dict[str, str]:
    """Dotted module name to source, nearest first."""
    modules: dict[str, str] = {}
    _add_tree(modules, source.parent, prefix=())
    sites: list[Path] = []
    if site_packages is not None:
        sites.append(site_packages)
    else:
        venv = _nearest_venv(source.parent)
        if venv is None and os.environ.get("VIRTUAL_ENV"):
            venv = Path(os.environ["VIRTUAL_ENV"])
        if venv is not None:
            sites += _site_packages(venv)
    for site in sites:
        for folder, declared in _search_paths(site):
            _add_declared(modules, folder, declared)
    for folder, declared in _build_environment():
        _add_declared(modules, folder, declared)
    return modules


def _add_tree(modules: dict[str, str], folder: Path, prefix: tuple[str, ...]) -> None:
    """Every ``.py`` file under ``folder``, a package's own source being its ``__init__.py``."""
    try:
        entries = sorted(folder.iterdir())
    except OSError:
        return
    for entry in entries:
        if entry.name.startswith(".") or entry.name in SKIPPED_FOLDERS:
            continue
        if entry.is_dir():
            if entry.name.isidentifier():
                _add_tree(modules, entry, (*prefix, entry.name))
        elif entry.suffix == ".py":
            stem = entry.stem
            parts = prefix if stem == "__init__" else (*prefix, stem)
            # `pyshader` itself is the compiler's builtin; what is installed
            # under it (`pyshader.stdlib`) is modules like any other.
            if parts and all(p.isidentifier() for p in parts) and parts != ("pyshader",):
                modules.setdefault(".".join(parts), entry.read_text(encoding="utf-8"))


def _add_declared(modules: dict[str, str], folder: Path, declared: set[str]) -> None:
    for module in sorted(declared):
        parts = module.split(".")
        # The packages above it (`shaderlib/__init__.py` for `shaderlib.noise`).
        for depth in range(1, len(parts)):
            if parts[:depth] == ["pyshader"]:
                continue
            init = folder.joinpath(*parts[:depth], "__init__.py")
            if init.is_file():
                modules.setdefault(".".join(parts[:depth]), init.read_text(encoding="utf-8"))
        file = folder.joinpath(*parts[:-1], parts[-1] + ".py")
        if file.is_file():
            modules.setdefault(module, file.read_text(encoding="utf-8"))
        package = folder.joinpath(*parts)
        if package.is_dir():
            _add_tree(modules, package, tuple(parts))


def _nearest_venv(folder: Path) -> Path | None:
    folder = folder.resolve()
    for candidate in (folder, *folder.parents):
        venv = candidate / ".venv"
        if venv.is_dir():
            return venv
    return None


def _site_packages(venv: Path) -> list[Path]:
    found = sorted(p for p in (venv / "lib").glob("python*/site-packages") if p.is_dir())
    windows = venv / "Lib" / "site-packages"
    if not found and windows.is_dir():
        found.append(windows)
    return found


def _search_paths(site: Path) -> list[tuple[Path, set[str]]]:
    """The folder and the ones its ``.pth`` files add, with the modules declared there."""
    declared: set[str] = set()
    folders = [site]
    try:
        entries = sorted(site.iterdir())
    except OSError:
        return []
    for entry in entries:
        if entry.name.endswith(".dist-info"):
            points = entry / "entry_points.txt"
            if points.is_file():
                declared |= declared_modules(points.read_text(encoding="utf-8"))
        elif entry.suffix == ".pth":
            for line in entry.read_text(encoding="utf-8").splitlines():
                path = line.strip()
                if not path or path.startswith("#") or path.startswith(("import ", "import\t")):
                    continue
                folder = Path(path) if Path(path).is_absolute() else site / path
                if folder.is_dir():
                    folders.append(folder)
    return [(folder, declared) for folder in folders]


def declared_modules(entry_points: str) -> set[str]:
    """The modules an ``entry_points.txt``'s ``[pyshader.modules]`` section names."""
    modules: set[str] = set()
    in_section = False
    for raw in entry_points.splitlines():
        line = raw.strip()
        if line.startswith("["):
            in_section = line == "[pyshader.modules]"
            continue
        if in_section and "=" in line:
            module = line.split("=", 1)[1].strip().split(":")[0].strip()
            if module:
                modules.add(module)
    return modules


def _build_environment() -> list[tuple[Path, set[str]]]:
    """The PyShader modules installed where the backend runs."""
    found: list[tuple[Path, set[str]]] = []
    for dist in importlib.metadata.distributions():
        declared = {ep.value.split(":")[0].strip() for ep in dist.entry_points if ep.group == "pyshader.modules"}
        if not declared:
            continue
        root = Path(str(dist.locate_file("")))
        found.append((root, declared))
        # An editable install keeps its source elsewhere, behind a .pth file.
        for file in dist.files or []:
            if file.suffix == ".pth":
                for line in Path(str(dist.locate_file(file))).read_text(encoding="utf-8").splitlines():
                    path = line.strip()
                    if path and not path.startswith(("#", "import ")) and Path(path).is_dir():
                        found.append((Path(path), declared))
    return found
