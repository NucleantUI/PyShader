"""PyShader's compiler, the Swift one, run as WebAssembly through wasmtime.

``pyshader.wasm`` is the module ``scripts/build_wasm.py`` builds (the one the
docs' previews run), shipped beside this file. ``PYSHADER_WASM`` points at
another build of it.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path

WASM_NAME = "pyshader.wasm"
# "line 12: message" for the shader itself, "noise.py, line 3: message" for a module.
_LOCATED = re.compile(r"^(?:(?P<file>[^\n]+?), )?line (?P<line>\d+): (?P<message>.*)$", re.DOTALL)


@dataclass
class CompileError(Exception):
    """A shader that does not compile: the message, and where."""

    message: str
    line: int | None = None
    #: The imported module's file the line is in; None for the shader itself.
    file: str | None = None

    @classmethod
    def parse(cls, text: str) -> CompileError:
        match = _LOCATED.match(text.strip())
        if match is None:
            return cls(text.strip())
        return cls(match["message"], int(match["line"]), match["file"])


def wasm_path() -> Path:
    override = os.environ.get("PYSHADER_WASM")
    path = Path(override) if override else Path(__file__).with_name(WASM_NAME)
    if not path.is_file():
        raise FileNotFoundError(
            f"PyShader's compiler is missing: {path} does not exist. It is built into the pyshader wheel by "
            "`uv run scripts/build_wasm.py` in a PyShader checkout; PYSHADER_WASM can point at a build of it."
        )
    return path


class Compiler:
    """One instance of the compiler; compiles any number of shaders, one at a time."""

    def __init__(self, path: Path | None = None):
        import wasmtime

        config = wasmtime.Config()
        try:
            config.cache = True   # the compiled machine code, reused by the next build
        except Exception:
            pass
        engine = wasmtime.Engine(config)
        module = wasmtime.Module.from_file(engine, str(path or wasm_path()))
        linker = wasmtime.Linker(engine)
        linker.define_wasi()
        self._store = wasmtime.Store(engine)
        self._store.set_wasi(wasmtime.WasiConfig())
        instance = linker.instantiate(self._store, module)
        exports = instance.exports(self._store)
        self._exports = exports
        self._memory = exports["memory"]
        exports["_initialize"](self._store)

    def _call(self, name: str, *args):
        return self._exports[name](self._store, *args)

    def _put(self, data: bytes) -> int:
        if not data:
            return 0
        pointer = self._call("pyshader_alloc", len(data))
        self._memory.write(self._store, data, pointer)
        return pointer

    def compile(self, source: str, options: str, modules: dict[str, str]) -> tuple[bytes, bytes]:
        """The compiled shader: SPIR-V words as bytes, or OpenGL ES 2 text as UTF-8,
        and for gles2 without ``single-file`` the vertex stage too (else ``b""``),
        the first being the fragment stage.

        Raises CompileError with the compiler's message and line.
        """
        self._call("pyshader_clear_modules")
        for name, text in modules.items():
            name_bytes, text_bytes = name.encode(), text.encode()
            n, t = self._put(name_bytes), self._put(text_bytes)
            self._call("pyshader_add_module", n, len(name_bytes), t, len(text_bytes))
            self._free(n, len(name_bytes))
            self._free(t, len(text_bytes))
        source_bytes, option_bytes = source.encode(), options.encode()
        s, o = self._put(source_bytes), self._put(option_bytes)
        failed = self._call("pyshader_compile", s, len(source_bytes), o, len(option_bytes))
        self._free(s, len(source_bytes))
        self._free(o, len(option_bytes))
        pointer, length = self._call("pyshader_result_ptr"), self._call("pyshader_result_len")
        result = bytes(self._memory.read(self._store, pointer, pointer + length)) if length else b""
        self._call("pyshader_result_free")
        if failed:
            raise CompileError.parse(result.decode("utf-8", errors="replace"))
        return result, self._vertex_stage()

    def _vertex_stage(self) -> bytes:
        length = self._call("pyshader_vertex_stage", 0, 0)
        if not length:
            return b""
        pointer = self._call("pyshader_alloc", length)
        self._call("pyshader_vertex_stage", pointer, length)
        data = bytes(self._memory.read(self._store, pointer, pointer + length))
        self._free(pointer, length)
        return data

    def _free(self, pointer: int, length: int) -> None:
        if pointer:
            self._call("pyshader_dealloc", pointer, length)
