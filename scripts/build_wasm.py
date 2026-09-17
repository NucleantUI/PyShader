#!/usr/bin/env python3
"""Build the two wasm modules the docs' WebGPU preview runs in the browser.

  PyShaderWasm/  Swift, WASI reactor: Python source -> SPIR-V (pyshader.wasm)
  NagaWasm/      Rust: SPIR-V -> WGSL (naga.wasm)

Both land in mkdocs-pyshader/mkdocs_pyshader/assets/. Needs a wasm Swift SDK
(`swift sdk list` shows one ending in `_wasm`; its toolchain is picked via
swiftly when the default one differs) and the wasm32-unknown-unknown Rust
target (`rustup target add wasm32-unknown-unknown`). wasm-opt is used when on
PATH. Overrides: PYSHADER_SWIFT, PYSHADER_WASM_SDK.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "mkdocs-pyshader" / "mkdocs_pyshader" / "assets"

SWIFT_PACKAGE = ROOT / "PyShaderWasm"
SWIFT_PRODUCT = "PyShaderWasm"
SWIFT_BUILT = SWIFT_PACKAGE / ".build" / "wasm32-unknown-wasip1" / "release" / f"{SWIFT_PRODUCT}.wasm"
# Reactor model (the host calls _initialize, then the exports), no debug info, size-optimised.
SWIFT_FLAGS = [
    "-c", "release",
    "-Xswiftc", "-Xclang-linker", "-Xswiftc", "-mexec-model=reactor",
    "-Xswiftc", "-gnone",
    "-Xswiftc", "-Osize",
    "-Xlinker", "--strip-all",
]

RUST_CRATE = ROOT / "NagaWasm"
RUST_BUILT = RUST_CRATE / "target" / "wasm32-unknown-unknown" / "release" / "naga_wasm.wasm"

VERSION_RE = re.compile(r"(\d+\.\d+(?:\.\d+)?)")


class BuildError(RuntimeError):
    pass


def _run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, capture_output=True, text=True, **kwargs)


def _toolchain_version(swift: str) -> str | None:
    match = VERSION_RE.search(_run([swift, "--version"]).stdout or "")
    return match.group(1) if match else None


def _available_sdks(swift: str) -> list[str]:
    out = _run([swift, "sdk", "list"]).stdout or ""
    return [line.strip() for line in out.splitlines() if line.strip().endswith("_wasm")]


def _swiftly_toolchains() -> set[str]:
    if shutil.which("swiftly") is None:
        return set()
    return set(VERSION_RE.findall(_run(["swiftly", "list"]).stdout or ""))


def resolve_swift(swift: str) -> tuple[list[str], str]:
    """A swift invocation and the wasm SDK whose versions match (an SDK only works with its own toolchain)."""
    sdks = _available_sdks(swift)
    if not sdks:
        raise BuildError(
            "No wasm Swift SDK installed. See https://www.swift.org/documentation/articles/wasm-getting-started.html"
        )
    requested = os.environ.get("PYSHADER_WASM_SDK")
    if requested:
        if requested not in sdks:
            raise BuildError(f"Swift SDK {requested!r} not found. Available: {sdks}")
        sdks = [requested]

    toolchain = _toolchain_version(swift)
    for sdk in sdks:
        match = VERSION_RE.search(sdk)
        if match and match.group(1) == toolchain:
            return [swift], sdk
    installed = _swiftly_toolchains()
    for sdk in sdks:
        match = VERSION_RE.search(sdk)
        if match and match.group(1) in installed:
            return ["swiftly", "run", f"+{match.group(1)}", swift], sdk
    raise BuildError(
        f"Swift toolchain {toolchain} matches none of the installed wasm SDKs ({sdks}). "
        "Install the matching toolchain (`swiftly install <version>`) or set PYSHADER_WASM_SDK."
    )


def build_swift() -> Path:
    swift = os.environ.get("PYSHADER_SWIFT", "swift")
    if shutil.which(swift) is None:
        raise BuildError(f"{swift!r} not found on PATH")
    prefix, sdk = resolve_swift(swift)
    command = [*prefix, "build", "--swift-sdk", sdk, *SWIFT_FLAGS]
    print("+", " ".join(command), flush=True)
    if subprocess.run(command, cwd=SWIFT_PACKAGE).returncode != 0:
        raise BuildError("swift build failed")
    if not SWIFT_BUILT.is_file():
        raise BuildError(f"expected {SWIFT_BUILT} after the build")
    return SWIFT_BUILT


def build_rust() -> Path:
    cargo = shutil.which("cargo", path=os.pathsep.join([str(Path.home() / ".cargo" / "bin"), os.environ.get("PATH", "")]))
    if cargo is None:
        raise BuildError("cargo not found; install Rust from https://rustup.rs")
    env = dict(os.environ)
    # rustup's cargo must see rustup's rustc, not a distro one without the wasm target.
    env["PATH"] = os.pathsep.join([str(Path.home() / ".cargo" / "bin"), env.get("PATH", "")])
    command = [cargo, "build", "--release", "--target", "wasm32-unknown-unknown"]
    print("+", " ".join(command), flush=True)
    if subprocess.run(command, cwd=RUST_CRATE, env=env).returncode != 0:
        raise BuildError("cargo build failed (is the target installed? rustup target add wasm32-unknown-unknown)")
    if not RUST_BUILT.is_file():
        raise BuildError(f"expected {RUST_BUILT} after the build")
    return RUST_BUILT


def install(built: Path, name: str, optimize: bool) -> Path:
    ASSETS.mkdir(parents=True, exist_ok=True)
    target = ASSETS / name
    wasm_opt = shutil.which("wasm-opt") if optimize else None
    if wasm_opt:
        command = [wasm_opt, "-Oz", "--strip-debug", "--strip-producers", "--enable-bulk-memory", "--enable-sign-ext",
                   "--enable-nontrapping-float-to-int", "--enable-mutable-globals", "--enable-reference-types",
                   "--enable-simd", str(built), "-o", str(target)]
        print("+", " ".join(command), flush=True)
        if subprocess.run(command).returncode != 0:
            raise BuildError("wasm-opt failed")
    else:
        shutil.copy2(built, target)
    print(f"wrote {target} ({target.stat().st_size / 1e6:.1f} MB)")
    return target


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", choices=["swift", "rust"], help="Build just one of the modules.")
    parser.add_argument("--no-opt", action="store_true", help="Skip wasm-opt.")
    args = parser.parse_args(argv)
    try:
        if args.only != "rust":
            install(build_swift(), "pyshader.wasm", not args.no_opt)
        if args.only != "swift":
            install(build_rust(), "naga.wasm", not args.no_opt)
    except BuildError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
