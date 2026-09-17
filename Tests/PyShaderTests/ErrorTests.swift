import Testing
@testable import PyShader

@Suite("Errors")
struct ErrorTests {
    @Test func missingEntryPoint() {
        compileError("def foo(x: float) -> float:\n    return x\n", contains: "entry point")
    }

    @Test func unknownInput() {
        compileError("def main(uv: float2, foo: float) -> float4:\n    return float4(1.0)\n", contains: "not a shader input", line: 1)
    }

    @Test func unannotatedParameter() {
        compileError("def f(x):\n    return x\ndef main(uv: float2) -> float4:\n    return float4(1.0)\n", contains: "type annotation", line: 1)
    }

    @Test func retypeVariable() {
        compileError("def main(uv: float2) -> float4:\n    x = 1\n    x = 1.5\n    return float4(x)\n", contains: "use int(...)", line: 3)
    }

    @Test func swizzleOutOfRange() {
        compileError("def main(uv: float2) -> float4:\n    return float4(uv.z)\n", contains: "out of range", line: 2)
    }

    @Test func repeatedSwizzleWrite() {
        compileError("def main(uv: float2) -> float4:\n    c = float3(1.0)\n    c.xx = float2(1.0)\n    return float4(c, 1.0)\n", contains: "repeated components", line: 3)
    }

    @Test func assignModuleVariableWithoutGlobal() {
        compileError("c = 1.0\ndef f():\n    global c\n    c = 2.0\ndef main(uv: float2) -> float4:\n    c += 1.0\n    return float4(c)\n", contains: "declare `global c`", line: 6)
    }

    @Test func globalOfUnknownName() {
        compileError("def main(uv: float2) -> float4:\n    global zz\n    return float4(1.0)\n", contains: "not assigned at module level", line: 2)
    }

    @Test func recursion() {
        compileError("""
        def f(a: float) -> float:
            return g(a)
        def g(a: float) -> float:
            return f(a)
        def main(uv: float2) -> float4:
            return float4(f(uv.x))
        """, contains: "recursion")
    }

    @Test func missingReturn() {
        compileError("def main(uv: float2) -> float4:\n    if uv.x > 0.5:\n        return float4(1.0)\n", contains: "must return")
    }

    @Test func keywordArguments() {
        compileError("def main(uv: float2) -> float4:\n    return float4(mix(uv, uv, t=0.5), 1.0, 1.0)\n", contains: "keyword arguments", line: 2)
    }

    @Test func classes() {
        compileError("class Foo:\n    pass\ndef main(uv: float2) -> float4:\n    return float4(1.0)\n", contains: "at least one field", line: 1)
        compileError("class Foo(Bar):\n    x: float\ndef main(uv: float2) -> float4:\n    return float4(1.0)\n", contains: "base classes", line: 1)
    }

    @Test func imports() {
        compileError("import math\ndef main(uv: float2) -> float4:\n    return float4(1.0)\n", contains: "cannot import", line: 1)
    }

    @Test func forOverNonRange() {
        compileError("def main(uv: float2) -> float4:\n    for i in uv:\n        pass\n    return float4(1.0)\n", contains: "range(...)", line: 2)
    }

    @Test func syntaxError() {
        compileError("def main(uv: float2) -> float4:\n    return float4(1.0\n", contains: "syntax error")
    }

    @Test func wrongEntryReturnType() {
        compileError("def main(uv: float2) -> float3:\n    return float3(1.0)\n", contains: "must return `float4`", line: 1)
    }

    @Test func vectorCondition() {
        compileError("def main(uv: float2) -> float4:\n    if uv > 0.5:\n        pass\n    return float4(1.0)\n", contains: "any()/all()", line: 2)
    }

    @Test func mixedSizedVectors() {
        compileError("def main(uv: float2) -> float4:\n    v = float3(1.0) + uv\n    return float4(v, 1.0)\n", contains: "cannot combine", line: 2)
    }
}
