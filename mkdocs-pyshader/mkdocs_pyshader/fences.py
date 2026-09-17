"""The three PyShader fences for pymdownx.superfences.

Each renders a `<div class="pyshader">` whose data attributes carry the
source and options; `pyshader-preview.js` turns them into live WebGPU
previews in the browser.
"""

from __future__ import annotations

import html
import json
import re
from pathlib import Path

# Fence options the validator accepts, with how the value is parsed.
_OPTIONS = {
    "file": str,
    "args": str,
    "content": str,
    "target": str,
    "height": str,
    "vertices": int,
    "instances": int,
    "title": str,
    "linenums": str,
    "hl_lines": str,
}

_ARG_KINDS = {"float", "float2", "float3", "float4", "floatArray"}
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


def _source(src: str, options: dict) -> str:
    if "file" in options:
        return (base_path / options["file"]).read_text(encoding="utf-8")
    return src


def _preview_div(source: str, options: dict, mode: str) -> str:
    data = {
        "mode": mode,
        "source": source,
        "target": options.get("target", "compute"),
        "args": _parse_args(options["args"]) if "args" in options else [],
    }
    for key in ("content", "height", "vertices", "instances"):
        if key in options:
            data[key] = options[key]
    height = options.get("height", "")
    if height.isdigit():
        height += "px"
    style = f' style="--pyshader-height:{height}"' if height else ""
    return (
        f'<div class="pyshader pyshader-{mode}"{style} data-pyshader="{html.escape(json.dumps(data), quote=True)}">'
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
