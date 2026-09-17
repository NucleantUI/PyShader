"""Registers the fences with superfences and ships the runtime assets."""

from __future__ import annotations

import json
import logging
import shutil
from pathlib import Path

from mkdocs.config import config_options
from mkdocs.plugins import BasePlugin

from . import fences

log = logging.getLogger("mkdocs.plugins.pyshader")

ASSETS = Path(__file__).parent / "assets"
WASM = ("pyshader.wasm", "naga.wasm")
FENCES = (
    ("pyshader", fences.code_and_preview),
    ("pyshader-preview", fences.preview_only),
    ("pyshader-edit", fences.editor),
)


class PyShaderPlugin(BasePlugin):
    config_scheme = (
        # Where the plugin's files are served from, under the site root.
        ("assets_dir", config_options.Type(str, default="assets/pyshader")),
        # Monaco's `vs` folder for the editor fence.
        ("monaco_url", config_options.Type(str, default="https://cdn.jsdelivr.net/npm/monaco-editor@0.52.2/min/vs")),
    )

    def on_config(self, config):
        fences.base_path = Path(config.config_file_path).parent

        extensions = config["markdown_extensions"]
        if "pymdownx.superfences" not in extensions:
            extensions.append("pymdownx.superfences")
        mdx = config["mdx_configs"].setdefault("pymdownx.superfences", {})
        custom = mdx.setdefault("custom_fences", [])
        present = {f.get("name") for f in custom}
        for name, formatter in FENCES:
            if name not in present:
                custom.append({"name": name, "class": name, "validator": fences.validator, "format": formatter})

        assets = self.config["assets_dir"].strip("/")
        config["extra_css"].append(f"{assets}/pyshader-preview.css")
        config["extra_javascript"].append(f"{assets}/pyshader-preview.js")
        return config

    def on_post_page(self, output, page, config):
        """Tells the runtime where the wasm modules, the site root and Monaco are."""
        site = "../" * page.url.count("/") if page.url else ""
        settings = {
            "assets": f"{site}{self.config['assets_dir'].strip('/')}/",
            "siteRoot": site or "./",
            "monaco": self.config["monaco_url"],
        }
        tag = f"<script>window.PyShaderConfig={json.dumps(settings)};</script>"
        return output.replace("</head>", tag + "</head>", 1) if "</head>" in output else output

    def on_post_build(self, config):
        target = Path(config["site_dir"]) / self.config["assets_dir"].strip("/")
        target.mkdir(parents=True, exist_ok=True)
        for name in ("pyshader-preview.js", "pyshader-preview.css", *WASM):
            source = ASSETS / name
            if source.exists():
                shutil.copy2(source, target / name)
            elif name in WASM:
                log.warning(
                    "pyshader: %s is missing; previews will not run. Build it with scripts/build_wasm.py", source
                )

