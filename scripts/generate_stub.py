"""Generates src/pyshader/__init__.py: the editor-facing view of the PyShader API.

Every vector type gets typed swizzle properties and operator overloads; every
builtin gets a signature. Bodies are `...` — the module only exists so an IDE
can type-check and complete shader source. Re-run after changing the API:

    uv run scripts/generate_stub.py
"""

from itertools import product
from pathlib import Path

SCALARS = {
    # name: (python base, vector component element name)
    "float": "float",
    "half": "half",
    "int": "int",
    "uint": "uint",
    "short": "short",
    "ushort": "ushort",
    "bool": "bool",
}
LETTERS = ("xyzw", "rgba")


def vector_name(scalar: str, n: int) -> str:
    return f"{scalar}{n}"


def swizzles(n: int):
    """All 1-4 letter swizzles over the first n components, both letter sets."""
    for letters in LETTERS:
        avail = letters[:n]
        for length in range(1, 5):
            for combo in product(avail, repeat=length):
                yield "".join(combo), length


def emit_scalar_classes(out: list[str]) -> None:
    out.append('''
class half(float):
    """16-bit float. Adds the SPIR-V Float16 capability; the device needs shaderFloat16."""

    def __new__(cls, value: float | int | bool = 0.0) -> "half": ...


class uint(int):
    """32-bit unsigned int. `uint(x)` reinterprets a negative int's bits."""

    def __new__(cls, value: float | int | bool = 0) -> "uint": ...


class short(int):
    """16-bit signed int. Adds the SPIR-V Int16 capability; the device needs shaderInt16."""

    def __new__(cls, value: float | int | bool = 0) -> "short": ...


class ushort(int):
    """16-bit unsigned int."""

    def __new__(cls, value: float | int | bool = 0) -> "ushort": ...
''')


def emit_vector_class(out: list[str], scalar: str, n: int) -> None:
    name = vector_name(scalar, n)
    elem = SCALARS[scalar]
    is_bool = scalar == "bool"
    is_float = scalar in ("float", "half")
    boolv = vector_name("bool", n)
    lines = [f"class {name}:"]
    lines.append(f'    """{n}-component {scalar} vector. Type name doubles as the constructor."""')
    lines.append("")
    # constructor: splat, components, vector+scalar flatten, truncate
    lines.append("    @overload")
    lines.append(f"    def __init__(self) -> None: ...")
    lines.append("    @overload")
    lines.append(f"    def __init__(self, splat: Scalar, /) -> None: ...")
    lines.append("    @overload")
    lines.append(f"    def __init__(self, *components: Scalar | AnyVector) -> None: ...")
    lines.append(f"    def __init__(self, *components: Any) -> None: ...")
    lines.append("")
    # swizzle properties
    for attr, length in swizzles(n):
        t = elem if length == 1 else vector_name(scalar, length)
        lines.append(f"    {attr}: {t}")
    lines.append("")
    # indexing / unpacking
    lines.append(f"    def __getitem__(self, index: int) -> {elem}: ...")
    lines.append(f"    def __setitem__(self, index: int, value: {elem} | int | float) -> None: ...")
    lines.append(f"    def __iter__(self) -> Iterator[{elem}]: ...")
    lines.append(f"    def __len__(self) -> int: ...")
    lines.append("")
    if is_bool:
        lines.append(f"    def __and__(self, other: {name} | bool) -> {name}: ...")
        lines.append(f"    def __or__(self, other: {name} | bool) -> {name}: ...")
        lines.append(f"    def __xor__(self, other: {name} | bool) -> {name}: ...")
        lines.append(f"    def __eq__(self, other: object) -> {name}: ...  # type: ignore[override]")
        lines.append(f"    def __ne__(self, other: object) -> {name}: ...  # type: ignore[override]")
    else:
        operand = f"{name} | Scalar"
        for op in ("add", "sub", "mul", "truediv", "floordiv", "mod", "pow"):
            lines.append(f"    def __{op}__(self, other: {operand}) -> {name}: ...")
            lines.append(f"    def __r{op}__(self, other: Scalar) -> {name}: ...")
        if not is_float:
            for op in ("and", "or", "xor", "lshift", "rshift"):
                lines.append(f"    def __{op}__(self, other: {operand}) -> {name}: ...")
            lines.append(f"    def __invert__(self) -> {name}: ...")
        lines.append(f"    def __neg__(self) -> {name}: ...")
        lines.append(f"    def __pos__(self) -> {name}: ...")
        for op in ("lt", "le", "gt", "ge"):
            lines.append(f"    def __{op}__(self, other: {operand}) -> {boolv}: ...")
        lines.append(f"    def __eq__(self, other: object) -> {boolv}: ...  # type: ignore[override]")
        lines.append(f"    def __ne__(self, other: object) -> {boolv}: ...  # type: ignore[override]")
    out.append("\n".join(lines) + "\n")


def emit_functions(out: list[str]) -> None:
    out.append('''
# ---------------------------------------------------------------------------
# Builtins (GLSL.std.450 names; Metal spellings as aliases). Ints promote to
# floats; a scalar broadcasts against a vector where GLSL allows it.
# ---------------------------------------------------------------------------

F = TypeVar("F", float, half, float2, float3, float4, half2, half3, half4)
"""Any float scalar or vector; result has the argument's shape."""
FV = TypeVar("FV", float2, float3, float4, half2, half3, half4)
"""Any float vector."""
N = TypeVar("N", float, int, uint, half, short, ushort,
            float2, float3, float4, half2, half3, half4,
            int2, int3, int4, uint2, uint3, uint4,
            short2, short3, short4, ushort2, ushort3, ushort4)
"""Any numeric scalar or vector."""
B = TypeVar("B", bool2, bool3, bool4)


# Trigonometry
def sin(x: F) -> F: ...
def cos(x: F) -> F: ...
def tan(x: F) -> F: ...
def asin(x: F) -> F: ...
def acos(x: F) -> F: ...
@overload
def atan(y_over_x: F) -> F: ...
@overload
def atan(y: F, x: F) -> F: ...
def atan(*args: Any) -> Any: ...
def atan2(y: F, x: F) -> F: ...
def sinh(x: F) -> F: ...
def cosh(x: F) -> F: ...
def tanh(x: F) -> F: ...
def asinh(x: F) -> F: ...
def acosh(x: F) -> F: ...
def atanh(x: F) -> F: ...
def radians(degrees: F) -> F: ...
def degrees(radians: F) -> F: ...


# Exponential
def pow(x: F, y: F | float) -> F: ...  # type: ignore[misc]
def exp(x: F) -> F: ...
def exp2(x: F) -> F: ...
def log(x: F) -> F: ...
def log2(x: F) -> F: ...
def sqrt(x: F) -> F: ...
def inversesqrt(x: F) -> F: ...
def rsqrt(x: F) -> F: ...


# Common
def abs(x: N) -> N: ...  # type: ignore[misc]
def sign(x: N) -> N: ...
def floor(x: F) -> F: ...
def ceil(x: F) -> F: ...
def round(x: F) -> F: ...  # type: ignore[misc]
def trunc(x: F) -> F: ...
def fract(x: F) -> F: ...
def mod(x: F, y: F | float) -> F: ...
def min(x: N, *others: N | float | int) -> N: ...  # type: ignore[misc]
def max(x: N, *others: N | float | int) -> N: ...  # type: ignore[misc]
def clamp(x: N, lo: N | float | int, hi: N | float | int) -> N: ...
def saturate(x: F) -> F: ...
def mix(a: F, b: F, t: F | float) -> F: ...
def lerp(a: F, b: F, t: F | float) -> F: ...
def step(edge: F | float, x: F) -> F: ...
def smoothstep(edge0: F | float, edge1: F | float, x: F) -> F: ...
def fma(a: F, b: F, c: F) -> F: ...
@overload
def isnan(x: float | half) -> bool: ...
@overload
def isnan(x: FV) -> bool2 | bool3 | bool4: ...
def isnan(x: Any) -> Any: ...
@overload
def isinf(x: float | half) -> bool: ...
@overload
def isinf(x: FV) -> bool2 | bool3 | bool4: ...
def isinf(x: Any) -> Any: ...


# Geometric
def length(v: F) -> float: ...
def distance(a: F, b: F) -> float: ...
def dot(a: FV, b: FV) -> float: ...
def cross(a: float3, b: float3) -> float3: ...
def normalize(v: FV) -> FV: ...
def faceforward(n: FV, i: FV, nref: FV) -> FV: ...
def reflect(i: FV, n: FV) -> FV: ...
def refract(i: FV, n: FV, eta: float) -> FV: ...


# Vector relational (on the boolN a vector comparison produces)
def any(v: B) -> bool: ...  # type: ignore[misc]
def all(v: B) -> bool: ...  # type: ignore[misc]


# Derivatives (fragment target only)
def dfdx(x: F) -> F: ...
def dfdy(x: F) -> F: ...
def dFdx(x: F) -> F: ...
def dFdy(x: F) -> F: ...
def fwidth(x: F) -> F: ...


# Fragment control
def discard() -> None:
    """Drops the pixel (OpKill). Statements after it never run."""
    ...


# Host resources
def layer(p: float2) -> float4:
    """The view the effect is applied to, sampled at `p` in [0, 1] (compute
    target with content, i.e. NucleantSwiftUI's `.shader(_:)`). `layer(uv)`
    is the pixel under the current one."""
    ...


class FloatArray:
    """A `.floatArray` ShaderArgument: `a[i]` (clamped to the ends, 0.0 when
    empty) and `len(a)`. Only usable as a `main` parameter."""

    def __getitem__(self, index: int) -> float: ...
    def __len__(self) -> int: ...
''')


def main() -> None:
    out: list[str] = []
    out.append('''"""PyShader — the shader API as seen from Python.

This module is documentation for editors: every type and builtin the PyShader
compiler understands, with signatures and no implementations. Import it at
the top of a shader file for completion and type checking; the compiler
ignores the import.

    from pyshader import *

    def main(uv: float2, time: float) -> float4:
        return float4(uv, 0.5 + 0.5 * sin(time), 1.0)

`main` takes its inputs by parameter name. Fragment target (NucleantVulkan
VKShader): uv, color, frag_coord, front_facing, time, resolution, mouse.
Compute target (NucleantSwiftUI Shader / .shader): uv, frag_coord, pixel,
time, time_delta, frame, resolution, mouse, mouse_click, plus every
ShaderArgument by name.

Generated by scripts/generate_stub.py — do not edit by hand.
"""

from typing import Any, Iterator, TypeVar, overload

__all__ = [
''')
    names = ["half", "uint", "short", "ushort", "FloatArray", "layer", "discard"]
    for scalar in SCALARS:
        for n in (2, 3, 4):
            names.append(vector_name(scalar, n))
    functions = [
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh",
        "asinh", "acosh", "atanh", "radians", "degrees", "pow", "exp", "exp2", "log",
        "log2", "sqrt", "inversesqrt", "rsqrt", "abs", "sign", "floor", "ceil", "round",
        "trunc", "fract", "mod", "min", "max", "clamp", "saturate", "mix", "lerp", "step",
        "smoothstep", "fma", "isnan", "isinf", "length", "distance", "dot", "cross",
        "normalize", "faceforward", "reflect", "refract", "any", "all", "dfdx", "dfdy",
        "dFdx", "dFdy", "fwidth",
    ]
    for n in names + functions:
        out.append(f'    "{n}",\n')
    out.append("]\n")
    out.append('''
Scalar = float | int | bool
"""A Python number literal or scalar value."""
''')
    emit_scalar_classes(out)
    out.append('''
AnyVector = Any
"""Placeholder while the vector classes are being declared."""

''')
    for scalar in SCALARS:
        for n in (2, 3, 4):
            emit_vector_class(out, scalar, n)
            out.append("\n")
    emit_functions(out)
    target = Path(__file__).resolve().parent.parent / "src" / "pyshader" / "__init__.py"
    target.write_text("".join(out))
    print(f"wrote {target} ({sum(1 for _ in target.open())} lines)")


if __name__ == "__main__":
    main()
