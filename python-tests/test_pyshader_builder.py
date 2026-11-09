"""The PEP 517 backend, on small projects in a temporary folder.

Needs ``src/pyshader_builder/pyshader.wasm`` (``uv run scripts/build_wasm.py``):
``uv run --group test pytest python-tests``.
"""

from __future__ import annotations

import base64
import hashlib
import tarfile
import textwrap
import zipfile
from pathlib import Path

import pytest

import pyshader_builder as backend
from pyshader_builder import _compiler, _config

GLOW = """\
def main(uv: float2, time: float) -> float4:
    d = length(uv - 0.5)
    return float4(float3(0.2, 0.5, 1.0) * (0.05 / d) * (0.75 + 0.25 * sin(time)), 1.0)
"""

PALETTE = """\
def ramp(t: float) -> float3:
    return mix(float3(0.1, 0.0, 0.3), float3(1.0, 0.7, 0.2), t)
"""

TINTED = """\
from palette import ramp


def main(uv: float2) -> float4:
    return float4(ramp(uv.x), 1.0)
"""

PYPROJECT = """\
[project]
name = "glow-app"
version = "1.2.0"
description = "A glowing widget"
readme = "README.md"
requires-python = ">=3.13"
license = "MIT"
authors = [{ name = "Ada", email = "ada@example.com" }]
dependencies = ["kivy>=2.3"]

[project.optional-dependencies]
dev = ["pytest; python_version >= '3.13'"]

[project.scripts]
glow = "glow_app.main:run"

[build-system]
requires = ["pyshader"]
build-backend = "pyshader_builder"
"""

pytestmark = pytest.mark.skipif(
    not (Path(backend.__file__).with_name("pyshader.wasm")).is_file(),
    reason="pyshader.wasm is not built (uv run scripts/build_wasm.py)",
)


def make_project(root: Path, shaders: str, files: dict[str, str] | None = None) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    (root / "pyproject.toml").write_text(PYPROJECT + "\n" + textwrap.dedent(shaders))
    (root / "README.md").write_text("# Glow\n")
    package = root / "src" / "glow_app"
    (package / "shaders").mkdir(parents=True)
    (package / "__init__.py").write_text("")
    (package / "main.py").write_text("def run():\n    pass\n")
    (package / "shaders" / "glow.py").write_text(GLOW)
    for name, text in (files or {}).items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    return root


SHADERS = """\
[tool.pyshader.glow]
source = "src/glow_app/shaders/glow.py"
output = "src/glow_app/shaders/glow.glsl"
target = "compute"
format = "gles2"

[tool.pyshader.tinted]
source = "shaders/tinted.py"
output = "src/glow_app/shaders/tinted.spv"
target = "compute"
"""


@pytest.fixture
def project(tmp_path, monkeypatch) -> Path:
    root = make_project(tmp_path / "glow-app", SHADERS, {"shaders/tinted.py": TINTED, "shaders/palette.py": PALETTE})
    monkeypatch.chdir(root)
    return root


def test_wheel_holds_the_compiled_shaders(project, tmp_path):
    out = tmp_path / "dist"
    out.mkdir()
    name = backend.build_wheel(str(out))
    assert name == "glow_app-1.2.0-py3-none-any.whl"
    with zipfile.ZipFile(out / name) as wheel:
        names = set(wheel.namelist())
        assert {"glow_app/__init__.py", "glow_app/main.py", "glow_app/shaders/glow.py",
                "glow_app/shaders/glow.glsl", "glow_app/shaders/tinted.spv"} <= names
        glsl = wheel.read("glow_app/shaders/glow.glsl").decode()
        assert glsl.startswith("---VERTEX SHADER---\n")
        assert "---FRAGMENT SHADER---" in glsl
        assert "gl_FragColor = py_main(tex_coord0, time);" in glsl
        spirv = wheel.read("glow_app/shaders/tinted.spv")
        assert spirv[:4] == bytes.fromhex("03022307")   # the SPIR-V magic, little-endian
        metadata = wheel.read("glow_app-1.2.0.dist-info/METADATA").decode()
        for line in ["Metadata-Version: 2.4", "Name: glow-app", "Version: 1.2.0", "Summary: A glowing widget",
                     "Requires-Python: >=3.13", "License-Expression: MIT", "Author-email: Ada <ada@example.com>",
                     "Requires-Dist: kivy>=2.3", "Provides-Extra: dev",
                     "Requires-Dist: pytest; (python_version >= '3.13') and extra == \"dev\"",
                     "Description-Content-Type: text/markdown"]:
            assert line in metadata.splitlines(), line
        assert metadata.endswith("# Glow\n")
        assert wheel.read("glow_app-1.2.0.dist-info/entry_points.txt").decode() == "[console_scripts]\nglow = glow_app.main:run\n\n"
        assert "Tag: py3-none-any" in wheel.read("glow_app-1.2.0.dist-info/WHEEL").decode()
        # Every file is in RECORD with its hash.
        record = dict(line.split(",", 1) for line in wheel.read("glow_app-1.2.0.dist-info/RECORD").decode().splitlines())
        for entry in names - {"glow_app-1.2.0.dist-info/RECORD"}:
            digest = base64.urlsafe_b64encode(hashlib.sha256(wheel.read(entry)).digest()).rstrip(b"=").decode()
            assert record[entry].startswith(f"sha256={digest},"), entry


def test_editable_writes_the_shaders_into_the_tree(project, tmp_path):
    out = tmp_path / "dist"
    out.mkdir()
    name = backend.build_editable(str(out))
    assert (project / "src/glow_app/shaders/glow.glsl").read_text().startswith("---VERTEX SHADER---")
    assert (project / "src/glow_app/shaders/tinted.spv").is_file()
    with zipfile.ZipFile(out / name) as wheel:
        pth = wheel.read("__editable__.glow_app-1.2.0.pth").decode()
    assert pth.strip() == str((project / "src").resolve())
    # A wheel built afterwards holds the fresh shader once, not the copy in the tree too.
    (project / "src/glow_app/shaders/glow.glsl").write_text("stale")
    with zipfile.ZipFile(out / backend.build_wheel(str(out))) as wheel:
        assert wheel.namelist().count("glow_app/shaders/glow.glsl") == 1
        assert wheel.read("glow_app/shaders/glow.glsl").decode() != "stale"


def test_sdist_carries_sources_not_shader_outputs(project, tmp_path):
    out = tmp_path / "dist"
    out.mkdir()
    (project / "src/glow_app/shaders/glow.glsl").write_text("built earlier")
    name = backend.build_sdist(str(out))
    assert name == "glow_app-1.2.0.tar.gz"
    with tarfile.open(out / name) as tar:
        names = set(tar.getnames())
    assert {"glow_app-1.2.0/pyproject.toml", "glow_app-1.2.0/PKG-INFO", "glow_app-1.2.0/shaders/tinted.py",
            "glow_app-1.2.0/shaders/palette.py", "glow_app-1.2.0/src/glow_app/shaders/glow.py"} <= names
    assert "glow_app-1.2.0/src/glow_app/shaders/glow.glsl" not in names


def test_what_opengl_es_2_cannot_do_stops_the_build_at_its_line(tmp_path, monkeypatch):
    root = make_project(tmp_path / "p", SHADERS.split("[tool.pyshader.tinted]")[0])
    (root / "src/glow_app/shaders/glow.py").write_text(
        "def main(uv: float2) -> float4:\n    k = int(uv.x * 8.0) & 3\n    return float4(float(k))\n"
    )
    monkeypatch.chdir(root)
    with pytest.raises(backend.ShaderBuildError) as raised:
        backend.build_wheel(str(tmp_path))
    message = str(raised.value)
    assert message.startswith("src/glow_app/shaders/glow.py:2: error: OpenGL ES 2 has no bitwise operators (`&`)\n")
    assert "\n    k = int(uv.x * 8.0) & 3\n" in message
    assert 'in [glow] of pyproject.toml [tool.pyshader], target = "compute", format = "gles2"' in message


def test_the_same_shader_compiles_to_spirv(tmp_path, monkeypatch):
    shaders = SHADERS.split("[tool.pyshader.tinted]")[0].replace('format = "gles2"', 'format = "spirv"').replace("glow.glsl", "glow.spv")
    root = make_project(tmp_path / "p", shaders)
    (root / "src/glow_app/shaders/glow.py").write_text(
        "def main(uv: float2) -> float4:\n    k = int(uv.x * 8.0) & 3\n    return float4(float(k))\n"
    )
    monkeypatch.chdir(root)
    with zipfile.ZipFile(tmp_path / backend.build_wheel(str(tmp_path))) as wheel:
        assert wheel.read("glow_app/shaders/glow.spv")[:4] == bytes.fromhex("03022307")


def test_pyshader_toml_is_read_like_the_swiftpm_plugins_read_it(tmp_path, monkeypatch):
    root = make_project(tmp_path / "p", "")
    (root / "pyshader.toml").write_text(
        '[glow]\nsource = "src/glow_app/shaders/glow.py"\noutput = "src/glow_app/shaders/glow.glsl"\n'
        'target = "compute"\nformat = "gles2"\n'
    )
    monkeypatch.chdir(root)
    with zipfile.ZipFile(tmp_path / backend.build_wheel(str(tmp_path))) as wheel:
        assert "glow_app/shaders/glow.glsl" in wheel.namelist()


def test_modules_from_a_site_packages_declaring_them(tmp_path, monkeypatch):
    site = tmp_path / "site"
    (site / "shaderlib").mkdir(parents=True)
    (site / "shaderlib" / "__init__.py").write_text("")
    (site / "shaderlib" / "palette.py").write_text(PALETTE)
    (site / "shaderlib-1.0.dist-info").mkdir()
    (site / "shaderlib-1.0.dist-info" / "entry_points.txt").write_text("[pyshader.modules]\nshaderlib = shaderlib\n")
    (site / "undeclared.py").write_text(PALETTE)
    shaders = f'[tool.pyshader]\nsite-packages = "{site}"\n\n' + SHADERS.split("[tool.pyshader.tinted]")[0]
    root = make_project(tmp_path / "p", shaders)
    (root / "src/glow_app/shaders/glow.py").write_text(TINTED.replace("from palette", "from shaderlib.palette"))
    monkeypatch.chdir(root)
    with zipfile.ZipFile(tmp_path / backend.build_wheel(str(tmp_path))) as wheel:
        assert "palette_ramp(" in wheel.read("glow_app/shaders/glow.glsl").decode().replace("shaderlib_", "")
    # Only declared packages are importable from a site-packages folder.
    (root / "src/glow_app/shaders/glow.py").write_text(TINTED.replace("from palette", "from undeclared"))
    with pytest.raises(backend.ShaderBuildError, match="undeclared"):
        backend.build_wheel(str(tmp_path))


def test_an_output_outside_the_packages_is_refused(tmp_path, monkeypatch):
    root = make_project(tmp_path / "p", SHADERS.split("[tool.pyshader.tinted]")[0].replace("src/glow_app/shaders/glow.glsl", "glow.glsl"))
    monkeypatch.chdir(root)
    with pytest.raises(backend.ShaderBuildError, match="outside the wheel's packages"):
        backend.build_wheel(str(tmp_path))


def test_configuration_mistakes():
    def error(table: dict) -> str:
        with pytest.raises(_config.ConfigError) as raised:
            _config.parse(table, "pyshader.toml")
        return str(raised.value)

    assert "no sections" in error({})
    assert "needs `source" in error({"a": {"output": "a.spv"}})
    assert "`format` is one of spirv, gles2" in error({"a": {"source": "a.py", "format": "glsl"}})
    assert "`target` is one of" in error({"a": {"source": "a.py", "target": "vertex"}})
    assert "unknown key `soruce`" in error({"a": {"source": "a.py", "soruce": "b.py"}})
    assert "spirv-opt" in error({"a": {"source": "a.py", "optimize": ["-O"]}})
    assert "two sections write" in error({"a": {"source": "a.py", "output": "x"}, "b": {"source": "b.py", "output": "x"}})
    config = _config.parse({"a": {"source": "a.py", "format": "gles2", "content-top-down": True, "arguments": ["g:float"]}}, "x")
    assert config.sections[0].output == "a.glsl"
    assert config.sections[0].options() == "target=fragment format=gles2 content-top-down=1 arg=g:float file=a.py"


def test_both_configurations_at_once_is_an_error(tmp_path):
    (tmp_path / "pyshader.toml").write_text('[a]\nsource = "a.py"\n')
    with pytest.raises(_config.ConfigError, match="keep one"):
        _config.load(tmp_path, {"tool": {"pyshader": {"b": {"source": "b.py"}}}})


def test_compile_errors_carry_their_line_and_module():
    assert _compiler.CompileError.parse("line 4: bad") == _compiler.CompileError("bad", 4, None)
    assert _compiler.CompileError.parse("noise.py, line 3: worse") == _compiler.CompileError("worse", 3, "noise.py")
    assert _compiler.CompileError.parse("no line") == _compiler.CompileError("no line")
