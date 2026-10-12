"""Generates src/pyshader/__init__.py: the editor-facing view of the PyShader API.

Every vector type gets typed swizzle properties and operator overloads; every
builtin gets a signature. Bodies are `...` — the module only exists so an IDE
can type-check and complete shader source. Re-run after changing the API:

    uv run scripts/generate_stub.py
"""

import math
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


def emit_matrix_class(out: list[str], scalar: str, cols: int, rows: int) -> None:
    name = f"{scalar}{cols}x{rows}"
    col = vector_name(scalar, rows)
    row = vector_name(scalar, cols)
    lines = [f"class {name}:"]
    lines.append(f'    """{cols} columns of {col}, column-major like Metal/GLSL. `*` and `@` are matrix products."""')
    lines.append("")
    lines.append("    @overload")
    lines.append("    def __init__(self) -> None:")
    lines.append('        """Identity."""')
    lines.append("    @overload")
    lines.append("    def __init__(self, diagonal: Scalar, /) -> None: ...")
    lines.append("    @overload")
    lines.append(f"    def __init__(self, *columns: {col}) -> None: ...")
    lines.append("    @overload")
    lines.append("    def __init__(self, *components: Scalar) -> None:")
    lines.append(f'        """{cols * rows} scalars, column-major."""')
    lines.append("    @overload")
    lines.append("    def __init__(self, other: AnyMatrix, /) -> None:")
    lines.append('        """Resize another matrix; new cells come from the identity."""')
    lines.append("    def __init__(self, *args: Any) -> None: ...")
    lines.append("")
    lines.append(f"    def __getitem__(self, column: int) -> {col}: ...")
    lines.append(f"    def __setitem__(self, column: int, value: {col}) -> None: ...")
    lines.append("    def __len__(self) -> int: ...")
    lines.append("")
    for op in ("mul", "matmul"):
        lines.append("    @overload")
        lines.append(f"    def __{op}__(self, other: {row}) -> {col}: ...")
        lines.append("    @overload")
        lines.append(f"    def __{op}__(self, other: {name}) -> {name}: ...")
        if op == "mul":
            lines.append("    @overload")
            lines.append(f"    def __mul__(self, other: Scalar) -> {name}: ...")
        lines.append(f"    def __{op}__(self, other: Any) -> Any: ...")
        lines.append("    @overload")
        lines.append(f"    def __r{op}__(self, other: {col}) -> {row}: ...")
        if op == "mul":
            lines.append("    @overload")
            lines.append(f"    def __rmul__(self, other: Scalar) -> {name}: ...")
        lines.append(f"    def __r{op}__(self, other: Any) -> Any: ...")
    lines.append(f"    def __add__(self, other: {name}) -> {name}: ...")
    lines.append(f"    def __sub__(self, other: {name}) -> {name}: ...")
    lines.append(f"    def __truediv__(self, other: Scalar) -> {name}: ...")
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


# Split and scale (Python's math order)
FV2 = TypeVar("FV2", float, float2, float3, float4)
"""A float scalar or vector, for the functions that pair it with an int of its shape."""


@overload
def modf(x: float) -> tuple[float, float]: ...
@overload
def modf(x: F) -> tuple[F, F]: ...
def modf(x: Any) -> Any:
    """(fraction, whole): whole is trunc(x), both signed like x."""
    ...
@overload
def frexp(x: float) -> tuple[float, int]: ...
@overload
def frexp(x: float2) -> tuple[float2, int2]: ...
@overload
def frexp(x: float3) -> tuple[float3, int3]: ...
@overload
def frexp(x: float4) -> tuple[float4, int4]: ...
def frexp(x: Any) -> Any:
    """(mantissa, exponent): x == mantissa * 2 ** exponent, |mantissa| in [0.5, 1)."""
    ...
def ldexp(x: FV2, e: int | int2 | int3 | int4) -> FV2: ...


# Packing
def packUnorm4x8(v: float4) -> uint: ...
def packSnorm4x8(v: float4) -> uint: ...
def packUnorm2x16(v: float2) -> uint: ...
def packSnorm2x16(v: float2) -> uint: ...
def packHalf2x16(v: float2) -> uint: ...
def unpackUnorm4x8(p: uint | int) -> float4: ...
def unpackSnorm4x8(p: uint | int) -> float4: ...
def unpackUnorm2x16(p: uint | int) -> float2: ...
def unpackSnorm2x16(p: uint | int) -> float2: ...
def unpackHalf2x16(p: uint | int) -> float2: ...
def pack_float_to_unorm4x8(v: float4) -> uint: ...
def pack_float_to_snorm4x8(v: float4) -> uint: ...
def pack_float_to_unorm2x16(v: float2) -> uint: ...
def pack_float_to_snorm2x16(v: float2) -> uint: ...
def unpack_unorm4x8_to_float(p: uint | int) -> float4: ...
def unpack_snorm4x8_to_float(p: uint | int) -> float4: ...
def unpack_unorm2x16_to_float(p: uint | int) -> float2: ...
def unpack_snorm2x16_to_float(p: uint | int) -> float2: ...


# Bits (32-bit integers; short / ushort widen first)
I = TypeVar("I", int, uint, int2, int3, int4, uint2, uint3, uint4)
"""Any integer scalar or vector."""


@overload
def bitCount(x: int | uint) -> int: ...
@overload
def bitCount(x: int2 | uint2) -> int2: ...
@overload
def bitCount(x: int3 | uint3) -> int3: ...
@overload
def bitCount(x: int4 | uint4) -> int4: ...
def bitCount(x: Any) -> Any:
    """Number of set bits, as an int (GLSL); `popcount` keeps the argument's type."""
    ...
def popcount(x: I) -> I: ...
def bitfieldReverse(x: I) -> I: ...
def reverse_bits(x: I) -> I: ...
def bitfieldExtract(x: I, offset: int, bits: int) -> I: ...
def extract_bits(x: I, offset: int, bits: int) -> I: ...
def bitfieldInsert(base: I, insert: I | int, offset: int, bits: int) -> I: ...
def insert_bits(base: I, insert: I | int, offset: int, bits: int) -> I: ...
@overload
def findLSB(x: int | uint) -> int: ...
@overload
def findLSB(x: int2 | uint2 | int3 | uint3 | int4 | uint4) -> int2 | int3 | int4: ...
def findLSB(x: Any) -> Any:
    """Index of the lowest set bit, -1 when none is set."""
    ...
@overload
def findMSB(x: int | uint) -> int: ...
@overload
def findMSB(x: int2 | uint2 | int3 | uint3 | int4 | uint4) -> int2 | int3 | int4: ...
def findMSB(x: Any) -> Any:
    """Index of the highest set bit (of a negative int: the highest clear bit), -1 when none."""
    ...
@overload
def floatBitsToInt(x: float) -> int: ...
@overload
def floatBitsToInt(x: float2 | float3 | float4) -> int2 | int3 | int4: ...
def floatBitsToInt(x: Any) -> Any: ...
@overload
def floatBitsToUint(x: float) -> uint: ...
@overload
def floatBitsToUint(x: float2 | float3 | float4) -> uint2 | uint3 | uint4: ...
def floatBitsToUint(x: Any) -> Any: ...
@overload
def intBitsToFloat(x: int) -> float: ...
@overload
def intBitsToFloat(x: int2 | int3 | int4) -> float2 | float3 | float4: ...
def intBitsToFloat(x: Any) -> Any: ...
@overload
def uintBitsToFloat(x: uint | int) -> float: ...
@overload
def uintBitsToFloat(x: uint2 | uint3 | uint4) -> float2 | float3 | float4: ...
def uintBitsToFloat(x: Any) -> Any: ...


# Geometric
def length(v: F) -> float: ...
def distance(a: F, b: F) -> float: ...
def dot(a: FV, b: FV) -> float: ...
def cross(a: float3, b: float3) -> float3: ...
def normalize(v: FV) -> FV: ...
def faceforward(n: FV, i: FV, nref: FV) -> FV: ...
def reflect(i: FV, n: FV) -> FV: ...
def refract(i: FV, n: FV, eta: float) -> FV: ...


# Matrices
M = TypeVar("M", float2x2, float2x3, float2x4, float3x2, float3x3, float3x4, float4x2, float4x3, float4x4,
            half2x2, half2x3, half2x4, half3x2, half3x3, half3x4, half4x2, half4x3, half4x4)
SQ = TypeVar("SQ", float2x2, float3x3, float4x4, half2x2, half3x3, half4x4)


def transpose(m: M) -> Any:
    """Columns become rows (a CxR matrix becomes RxC)."""
    ...
def determinant(m: SQ) -> float: ...
def inverse(m: SQ) -> SQ: ...
def outerProduct(c: FV, r: FV) -> Any:
    """Column vector c times row vector r: len(r) columns of len(c) rows."""
    ...


# Vector relational (on the boolN a vector comparison produces)
def any(v: B) -> bool: ...  # type: ignore[misc]
def all(v: B) -> bool: ...  # type: ignore[misc]


# Derivatives (fragment target only)
def dfdx(x: F) -> F: ...
def dfdy(x: F) -> F: ...
def dFdx(x: F) -> F: ...
def dFdy(x: F) -> F: ...
def fwidth(x: F) -> F: ...
def dFdxFine(x: F) -> F: ...
def dFdyFine(x: F) -> F: ...
def fwidthFine(x: F) -> F: ...
def dFdxCoarse(x: F) -> F: ...
def dFdyCoarse(x: F) -> F: ...
def fwidthCoarse(x: F) -> F: ...
def dfdx_fine(x: F) -> F: ...
def dfdy_fine(x: F) -> F: ...
def fwidth_fine(x: F) -> F: ...
def dfdx_coarse(x: F) -> F: ...
def dfdy_coarse(x: F) -> F: ...
def fwidth_coarse(x: F) -> F: ...


# Driver hints: they change nothing a shader computes
def unroll(r: range) -> range:
    """`for i in unroll(range(4)):` asks the driver to unroll the loop."""
    return r
def dont_unroll(r: range) -> range:
    """`for i in dont_unroll(range(n)):` asks the driver to keep the loop."""
    return r
def inline(f: Any) -> Any:
    """`@inline` on a function: a hint to inline its calls."""
    return f
def noinline(f: Any) -> Any:
    """`@noinline` on a function: a hint to keep it a call."""
    return f


# Fragment control
def discard() -> None:
    """Drops the pixel (OpKill). Statements after it never run."""
    ...


# Constants
PI: float = __PI__
"""π. The compiler emits the nearest `float` to it, so nothing needs defining."""


# Host resources
def layer(p: float2) -> float4:
    """The view the effect is applied to, sampled at `p` in [0, 1] (compute
    target with content, i.e. NucleantUI's `.shader(_:)`). `layer(uv)`
    is the pixel under the current one."""
    ...


class FloatArray:
    """A `.floatArray` ShaderArgument: `a[i]` (clamped to the ends, 0.0 when
    empty) and `len(a)`. Only usable as an entry point parameter."""

    def __getitem__(self, index: int) -> float: ...
    def __len__(self) -> int: ...


class Float2Array:
    """A `.float2Array` ShaderArgument: `a[i]` is a `float2` (clamped to the
    ends, zeros when empty) and `len(a)` counts them."""

    def __getitem__(self, index: int) -> float2: ...
    def __len__(self) -> int: ...


class Float3Array:
    """A `.float3Array` ShaderArgument: `a[i]` is a `float3` (clamped to the
    ends, zeros when empty) and `len(a)` counts them."""

    def __getitem__(self, index: int) -> float3: ...
    def __len__(self) -> int: ...


class Float4Array:
    """A `.float4Array` ShaderArgument: `a[i]` is a `float4` (clamped to the
    ends, zeros when empty) and `len(a)` counts them."""

    def __getitem__(self, index: int) -> float4: ...
    def __len__(self) -> int: ...
'''.replace("__PI__", repr(math.pi)))


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

Functions return several values as tuples (`-> tuple[float, float3]`, then
`t, n = f(...)`); fixed-size arrays are list literals (`[float4(0.0)] * 3`,
`xs: list[float] = [...]`); matrices are `float2x2` ... `float4x4`.

`main` takes its inputs by parameter name. Fragment target (NucleantVulkan
VKShader): uv, color, frag_coord, front_facing, time, resolution, mouse.
Compute target (NucleantUI Shader / .shader): uv, frag_coord, pixel,
time, time_delta, frame, resolution, mouse, mouse_click, plus every
ShaderArgument by name.

Generated by scripts/generate_stub.py — do not edit by hand.
"""

from typing import Any, Iterator, TypeVar, overload

__all__ = [
''')
    names = ["half", "uint", "short", "ushort", "FloatArray", "Float2Array", "Float3Array", "Float4Array",
             "PI", "layer", "discard"]
    for scalar in SCALARS:
        for n in (2, 3, 4):
            names.append(vector_name(scalar, n))
    for scalar in ("float", "half"):
        for c in (2, 3, 4):
            for r in (2, 3, 4):
                names.append(f"{scalar}{c}x{r}")
    functions = [
        "transpose", "determinant", "inverse",
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh",
        "asinh", "acosh", "atanh", "radians", "degrees", "pow", "exp", "exp2", "log",
        "log2", "sqrt", "inversesqrt", "rsqrt", "abs", "sign", "floor", "ceil", "round",
        "trunc", "fract", "mod", "min", "max", "clamp", "saturate", "mix", "lerp", "step",
        "smoothstep", "fma", "isnan", "isinf", "length", "distance", "dot", "cross",
        "normalize", "faceforward", "reflect", "refract", "any", "all", "dfdx", "dfdy",
        "dFdx", "dFdy", "fwidth", "dFdxFine", "dFdyFine", "fwidthFine", "dFdxCoarse", "dFdyCoarse",
        "fwidthCoarse", "dfdx_fine", "dfdy_fine", "fwidth_fine", "dfdx_coarse", "dfdy_coarse",
        "fwidth_coarse", "outerProduct", "modf", "frexp", "ldexp",
        "packUnorm4x8", "packSnorm4x8", "packUnorm2x16", "packSnorm2x16", "packHalf2x16",
        "unpackUnorm4x8", "unpackSnorm4x8", "unpackUnorm2x16", "unpackSnorm2x16", "unpackHalf2x16",
        "pack_float_to_unorm4x8", "pack_float_to_snorm4x8", "pack_float_to_unorm2x16",
        "pack_float_to_snorm2x16", "unpack_unorm4x8_to_float", "unpack_snorm4x8_to_float",
        "unpack_unorm2x16_to_float", "unpack_snorm2x16_to_float",
        "bitCount", "popcount", "bitfieldReverse", "reverse_bits", "bitfieldExtract", "extract_bits",
        "bitfieldInsert", "insert_bits", "findLSB", "findMSB",
        "floatBitsToInt", "floatBitsToUint", "intBitsToFloat", "uintBitsToFloat",
        "unroll", "dont_unroll", "inline", "noinline",
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
    out.append("\nAnyMatrix = Any\n" + chr(34) * 3 + "Placeholder while the matrix classes are being declared." + chr(34) * 3 + "\n\n")
    for scalar in ("float", "half"):
        for c in (2, 3, 4):
            for r in (2, 3, 4):
                emit_matrix_class(out, scalar, c, r)
                out.append("\n")
    emit_functions(out)
    target = Path(__file__).resolve().parent.parent / "src" / "pyshader" / "__init__.py"
    target.write_text("".join(out))
    print(f"wrote {target} ({sum(1 for _ in target.open())} lines)")


if __name__ == "__main__":
    main()
