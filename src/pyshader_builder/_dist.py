"""Wheels and sdists from ``pyproject.toml``'s ``[project]`` table (PEP 621).

Only static metadata: a project that marks fields ``dynamic`` needs another
backend for them.
"""

from __future__ import annotations

import base64
import hashlib
import io
import os
import re
import tarfile
import time
import zipfile
from pathlib import Path

GENERATOR = "pyshader_builder"
#: Never packed into a wheel or an sdist.
SKIPPED = {"__pycache__", ".git", ".hg", ".svn", ".venv", "venv", ".tox", ".nox", "dist", "build", ".build",
           ".swiftpm", "node_modules", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".DS_Store"}


class ProjectError(Exception):
    """A ``[project]`` table this backend cannot build."""


def normalize(name: str) -> str:
    """The distribution name as file names spell it (``my-app`` -> ``my_app``)."""
    return re.sub(r"[-_.]+", "_", name).lower()


class Project:
    def __init__(self, root: Path, pyproject: dict):
        self.root = root
        project = pyproject.get("project")
        if not isinstance(project, dict):
            raise ProjectError("pyproject.toml needs a [project] table")
        if project.get("dynamic"):
            raise ProjectError(f"pyshader_builder reads only static metadata; [project] dynamic = {project['dynamic']!r}")
        for key in ("name", "version"):
            if not isinstance(project.get(key), str):
                raise ProjectError(f"[project] needs a `{key}`")
        self.table = project
        self.name: str = project["name"]
        self.version: str = project["version"]
        self.dist = normalize(self.name)

    @property
    def dist_info(self) -> str:
        return f"{self.dist}-{self.version}.dist-info"

    # MARK: Metadata

    def metadata(self) -> str:
        p = self.table
        m = _Headers()
        m["Metadata-Version"] = "2.4"
        m["Name"] = self.name
        m["Version"] = self.version
        if p.get("description"):
            m["Summary"] = p["description"]
        if p.get("requires-python"):
            m["Requires-Python"] = p["requires-python"]
        license = p.get("license")
        if isinstance(license, str):
            m["License-Expression"] = license
        elif isinstance(license, dict) and "text" in license:
            m["License"] = license["text"]
        elif isinstance(license, dict) and "file" in license:
            m["License"] = (self.root / license["file"]).read_text(encoding="utf-8")
        for field, header in (("authors", "Author"), ("maintainers", "Maintainer")):
            people = p.get(field, [])
            names = [x["name"] for x in people if "name" in x and "email" not in x]
            emails = [f"{x['name']} <{x['email']}>" if "name" in x else x["email"] for x in people if "email" in x]
            if names:
                m[header] = ", ".join(names)
            if emails:
                m[header + "-email"] = ", ".join(emails)
        if p.get("keywords"):
            m["Keywords"] = ",".join(p["keywords"])
        for classifier in p.get("classifiers", []):
            m["Classifier"] = classifier
        for label, url in p.get("urls", {}).items():
            m["Project-URL"] = f"{label}, {url}"
        for requirement in p.get("dependencies", []):
            m["Requires-Dist"] = requirement
        for extra, requirements in p.get("optional-dependencies", {}).items():
            m["Provides-Extra"] = extra
            for requirement in requirements:
                m["Requires-Dist"] = self._with_extra(requirement, extra)
        body = ""
        readme = p.get("readme")
        if readme is not None:
            text, content_type = self._readme(readme)
            m["Description-Content-Type"] = content_type
            body = text
        return m.text() + "\n" + body

    @staticmethod
    def _with_extra(requirement: str, extra: str) -> str:
        if ";" in requirement:
            spec, marker = requirement.split(";", 1)
            return f'{spec.strip()}; ({marker.strip()}) and extra == "{extra}"'
        return f'{requirement}; extra == "{extra}"'

    def _readme(self, readme) -> tuple[str, str]:
        types = {".md": "text/markdown", ".rst": "text/x-rst"}
        if isinstance(readme, str):
            return (self.root / readme).read_text(encoding="utf-8"), types.get(Path(readme).suffix.lower(), "text/plain")
        if "file" in readme:
            text = (self.root / readme["file"]).read_text(encoding="utf-8")
            return text, readme.get("content-type", types.get(Path(readme["file"]).suffix.lower(), "text/plain"))
        return readme.get("text", ""), readme.get("content-type", "text/plain")

    def entry_points(self) -> str:
        groups: dict[str, dict[str, str]] = {}
        if self.table.get("scripts"):
            groups["console_scripts"] = self.table["scripts"]
        if self.table.get("gui-scripts"):
            groups["gui_scripts"] = self.table["gui-scripts"]
        groups.update(self.table.get("entry-points", {}))
        out = ""
        for group, points in groups.items():
            out += f"[{group}]\n" + "".join(f"{k} = {v}\n" for k, v in points.items()) + "\n"
        return out

    # MARK: Packages

    def packages(self, configured: tuple[str, ...] | None) -> list[Path]:
        """The folders (or single modules) the wheel holds, each at its import name."""
        if configured is not None:
            found = [self.root / p for p in configured]
            for path in found:
                if not path.exists():
                    raise ProjectError(f"package `{path.relative_to(self.root)}` does not exist")
            return found
        import_name = self.dist
        for candidate in (self.root / "src" / import_name, self.root / import_name,
                          self.root / "src" / f"{import_name}.py", self.root / f"{import_name}.py"):
            if candidate.exists():
                return [candidate]
        raise ProjectError(
            f"no package `{import_name}` in src/ or at the root; list the wheel's packages as "
            '`packages = ["src/mypackage"]` in [tool.pyshader]'
        )

    @staticmethod
    def files(folder: Path) -> list[Path]:
        if folder.is_file():
            return [folder]
        out = []
        for dirpath, dirnames, filenames in os.walk(folder):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIPPED)
            for name in sorted(filenames):
                if name in SKIPPED or name.endswith((".pyc", ".pyo")):
                    continue
                out.append(Path(dirpath) / name)
        return out


class WheelWriter:
    """A ``py3-none-any`` wheel, its RECORD written last."""

    def __init__(self, directory: Path, project: Project, tag: str = "py3-none-any"):
        self.project = project
        self.name = f"{project.dist}-{project.version}-{tag}.whl"
        self.path = directory / self.name
        self._zip = zipfile.ZipFile(self.path, "w", compression=zipfile.ZIP_DEFLATED)
        self._records: list[str] = []
        self._tag = tag

    def add(self, arcname: str, data: bytes) -> None:
        info = zipfile.ZipInfo(arcname, date_time=_timestamp())
        info.external_attr = 0o644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        self._zip.writestr(info, data)
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        self._records.append(f"{arcname},sha256={digest},{len(data)}")

    def close(self) -> str:
        p = self.project
        info = p.dist_info
        self.add(f"{info}/METADATA", p.metadata().encode())
        wheel = f"Wheel-Version: 1.0\nGenerator: {GENERATOR}\nRoot-Is-Purelib: true\nTag: {self._tag}\n"
        self.add(f"{info}/WHEEL", wheel.encode())
        entry_points = p.entry_points()
        if entry_points:
            self.add(f"{info}/entry_points.txt", entry_points.encode())
        record = "\n".join(self._records + [f"{info}/RECORD,,"]) + "\n"
        info_ = zipfile.ZipInfo(f"{info}/RECORD", date_time=_timestamp())
        info_.external_attr = 0o644 << 16
        self._zip.writestr(info_, record)
        self._zip.close()
        return self.name


def write_sdist(directory: Path, project: Project, extra_skipped: set[Path]) -> str:
    """The project's files under ``<name>-<version>/``, with a PKG-INFO."""
    base = f"{project.dist}-{project.version}"
    name = f"{base}.tar.gz"
    with tarfile.open(directory / name, "w:gz", format=tarfile.PAX_FORMAT) as tar:
        def add(arcname: str, data: bytes) -> None:
            info = tarfile.TarInfo(f"{base}/{arcname}")
            info.size = len(data)
            info.mtime = int(time.time())
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))

        for file in Project.files(project.root):
            if file.resolve() in extra_skipped or file.suffix in (".whl",):
                continue
            add(file.relative_to(project.root).as_posix(), file.read_bytes())
        add("PKG-INFO", project.metadata().encode())
    return name


def _timestamp() -> tuple[int, int, int, int, int, int]:
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", time.time()))
    return time.gmtime(max(epoch, 315532800))[:6]


class _Headers:
    """Core metadata headers in order, unfolded; a multi-line value continues indented."""

    def __init__(self):
        self._lines: list[str] = []

    def __setitem__(self, key: str, value: str) -> None:
        self._lines.append(f"{key}: " + str(value).replace("\n", "\n        "))

    def text(self) -> str:
        return "\n".join(self._lines) + "\n"
