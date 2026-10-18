"""The PyShader fences for pymdownx.superfences.

Each renders a `<div class="pyshader">` whose data attributes carry the
source and options; `pyshader-preview.js` turns them into live WebGPU
previews in the browser. `pyshader-convert` is the odd one out: a GLSL
editor whose contents come back as PyShader source.
"""

from __future__ import annotations

import ast
import html
import json
import re
import sys
from pathlib import Path

# Fence options the validator accepts, with how the value is parsed.
_OPTIONS = {
    "file": str,
    "modules": str,
    "module": str,
    "examples": str,
    "args": str,
    "content": str,
    "target": str,
    "height": str,
    "aspect": str,
    "layout": str,
    "debounce": int,
    "vertices": int,
    "instances": int,
    "title": str,
    "linenums": str,
    "hl_lines": str,
}

_ARG_KINDS = {"float", "float2", "float3", "float4",
              "floatArray", "float2Array", "float3Array", "float4Array"}
_ASPECT_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*[:/]\s*(\d+(?:\.\d+)?)\s*$")
_LAYOUTS = {"auto", "horizontal", "vertical"}
_ARG_RE = re.compile(r"^\s*(?P<name>[A-Za-z_]\w*)\s*:\s*(?P<kind>\w+)\s*(?:=\s*(?P<value>[^,;]+))?\s*$")

# Set by the plugin: where `file=` paths resolve from.
base_path: Path = Path(".")


def validator(language, inputs, options, attrs, md):
    for key, value in inputs.items():
        if key in _OPTIONS and value is not True:
            try:
                options[key] = _OPTIONS[key](value)
            except ValueError:
                return False
            if key == "aspect" and not _ASPECT_RE.match(value):
                return False
            if key == "layout" and value not in _LAYOUTS:
                return False
        else:
            attrs[key] = value
    return True


def _parse_args(spec: str) -> list[dict]:
    """`radius:float=40, tint:float4=1 0.5 0 1, mins:floatArray=0.1 0.2` -> declarations."""
    args = []
    for item in spec.split(","):
        if not item.strip():
            continue
        m = _ARG_RE.match(item)
        if not m or m["kind"] not in _ARG_KINDS:
            raise ValueError(f"bad pyshader arg `{item.strip()}`; want name:kind[=value]")
        values = [float(v) for v in m["value"].split()] if m["value"] else []
        args.append({"name": m["name"], "kind": m["kind"], "value": values})
    return args


def folder_modules(folder: Path, prefix: str = "") -> dict[str, str]:
    """Every `.py` file under `folder` as a module, by dotted name relative to
    it (`palettes`, `shaderlib.noise`; a package's own source is its
    `__init__.py`)."""
    sources = {}
    for path in sorted(folder.rglob("*.py")):
        parts = list(path.relative_to(folder).with_suffix("").parts)
        if "__pycache__" in parts:
            continue
        if parts[-1] == "__init__":
            parts.pop()
        name = ".".join(([prefix] if prefix else []) + parts)
        if name:
            sources[name] = path.read_text(encoding="utf-8")
    return sources


def module_sources(package: str) -> dict[str, str]:
    """The sources of the package `package` (dotted) and everything below
    it, from the first `sys.path` entry that has it."""
    relative = Path(*package.split("."))
    for entry in sys.path:
        root = Path(entry or ".")
        if (root / relative).is_dir():
            return folder_modules(root / relative, package)
        single = (root / relative).with_suffix(".py")
        if single.is_file():
            return {package: single.read_text(encoding="utf-8")}
    return {}


def _source(src: str, options: dict) -> str:
    if "file" in options:
        return (base_path / options["file"]).read_text(encoding="utf-8")
    return src


def _preview_div(source: str, options: dict, mode: str) -> str:
    data = {
        "mode": mode,
        "source": source,
        "args": _parse_args(options["args"]) if "args" in options else [],
    }
    # `modules="Examples/imports"`: the local modules this preview's source imports.
    if "modules" in options:
        data["modules"] = folder_modules(base_path / options["modules"])
    # No `target`: the preview reads it off the source, and off each edit.
    for key in ("target", "content", "height", "vertices", "instances", "debounce"):
        if key in options:
            data[key] = options[key]
    styles = []
    height = options.get("height", "")
    if height.isdigit():
        height += "px"
    if height:
        styles.append(f"--pyshader-height:{height}")
    if "aspect" in options:
        w, h = _ASPECT_RE.match(options["aspect"]).groups()
        styles.append(f"--pyshader-aspect:{w}/{h}")
    style = f' style="{";".join(styles)}"' if styles else ""
    classes = [f"pyshader-{mode}"]
    if "aspect" in options:
        classes.append("pyshader-has-aspect")
    if mode == "edit":
        classes.append(f"pyshader-layout-{options.get('layout', 'auto')}")
    return (
        f'<div class="pyshader {" ".join(classes)}"{style} data-pyshader="{html.escape(json.dumps(data), quote=True)}">'
        '<div class="pyshader-frame"><canvas class="pyshader-canvas"></canvas>'
        '<div class="pyshader-status"></div></div></div>'
    )


def _code_block(source: str, options: dict, md, **kwargs) -> str:
    hl_options = {k: options[k] for k in ("title", "linenums", "hl_lines") if k in options}
    return md.preprocessors["fenced_code_block"].highlight(
        src=source,
        language="python",
        options=hl_options,
        md=md,
        classes=kwargs.get("classes") or [],
        id_value=kwargs.get("id_value", ""),
        attrs=kwargs.get("attrs") or {},
    )


def code_and_preview(src, language, css_class, options, md, **kwargs):
    source = _source(src, options)
    return _code_block(source, options, md, **kwargs) + _preview_div(source, options, "preview")


def preview_only(src, language, css_class, options, md, **kwargs):
    return _preview_div(_source(src, options), options, "preview")


def editor(src, language, css_class, options, md, **kwargs):
    return _preview_div(_source(src, options), options, "edit")


def converter(src, language, css_class, options, md, **kwargs):
    """GLSL in, PyShader out. `examples="dir"` offers every .glsl file in it in a picker;
    the fence body (or `file=`) is the initial source, else the first example."""
    examples = []
    if "examples" in options:
        folder = base_path / options["examples"]
        for path in sorted(folder.glob("*.glsl")):
            examples.append({"name": path.stem, "source": path.read_text(encoding="utf-8")})
    source = _source(src, options).strip("\n")
    if not source and examples:
        source = examples[0]["source"]
    data = {"source": source, "examples": examples}
    height = options.get("height", "")
    if height.isdigit():
        height += "px"
    style = f' style="--pyshader-height:{height}"' if height else ""
    return (
        f'<div class="pyshader-convert"{style} data-pyshader-convert="{html.escape(json.dumps(data), quote=True)}">'
        '<div class="pyshader-status pyshader-status-busy">Loading the converter…</div></div>'
    )


def _first_paragraph(doc: str | None) -> str:
    if not doc:
        return ""
    return " ".join(doc.strip().split("\n\n")[0].split())


def _inline_code(text: str) -> str:
    """Docstring text with `code` spans kept, everything else escaped."""
    parts = text.split("`")
    return "".join(f"<code>{html.escape(p)}</code>" if i % 2 else html.escape(p) for i, p in enumerate(parts))


def api_reference(src, language, css_class, options, md, **kwargs):
    """`pyshader-api module="pyshader.stdlib.fragment.sdf"`: the module's public
    functions and constants, read from the installed source, one row each with
    its signature and the first paragraph of its docstring."""
    name = options.get("module", src.strip())
    source = module_sources(name).get(name)
    if source is None:
        raise ValueError(f"pyshader-api: module `{name}` is not installed where MkDocs runs")
    tree = ast.parse(source)
    rows = []
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and not node.name.startswith("_"):
            params = ", ".join(
                f"{a.arg}: {ast.unparse(a.annotation)}" if a.annotation else a.arg for a in node.args.args
            )
            returns = f" -> {ast.unparse(node.returns)}" if node.returns else ""
            signature = f"{node.name}({params}){returns}"
            rows.append((node.name, signature, _first_paragraph(ast.get_docstring(node))))
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            target = node.targets[0] if isinstance(node, ast.Assign) else node.target
            if isinstance(target, ast.Name) and target.id.isupper() and not target.id.startswith("_") and node.value is not None:
                value = ast.unparse(node.value)
                if "\n" in value or len(value) > 70:
                    value = value.split("(")[0] + "(…)"
                rows.append((target.id, f"{target.id} = {value}", "Constant."))
    body = "".join(
        f'<tr id="{html.escape(name.split(".")[-1])}-{html.escape(row_name)}"><td><code>{html.escape(signature)}</code></td>'
        f"<td>{_inline_code(doc)}</td></tr>"
        for row_name, signature, doc in rows
    )
    module_doc = _first_paragraph(ast.get_docstring(tree))
    caption = f"<p class=\"pyshader-api-doc\">{_inline_code(module_doc)}</p>" if module_doc else ""
    return (
        f'<div class="pyshader-api"><p class="pyshader-api-module"><code>{html.escape(name)}</code></p>{caption}'
        f"<table><thead><tr><th>Name</th><th>What it does</th></tr></thead><tbody>{body}</tbody></table></div>"
    )
