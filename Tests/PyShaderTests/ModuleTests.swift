import Foundation
import Testing
@testable import PyShader

/// The `OpName` strings of a module.
private func names(_ words: SpirvWords) -> [String] {
    words.instructions.filter { $0.opcode == SpirvOp.opName.rawValue }.map { string(Array($0.operands.dropFirst())) }
}

/// The `OpString` strings of a module.
private func strings(_ words: SpirvWords) -> [String] {
    words.instructions.filter { $0.opcode == SpirvOp.opString.rawValue }.map { string(Array($0.operands.dropFirst())) }
}

private func string(_ operands: [UInt32]) -> String {
    var bytes: [UInt8] = []
    for word in operands {
        for k in 0..<4 {
            let b = UInt8((word >> (8 * k)) & 0xFF)
            if b == 0 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(b)
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

@discardableResult
private func compileModules(_ source: String, _ sources: [String: String], sourceFile: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws -> SpirvWords {
    let shader = try PyShader.compile(source, target: .nucleant, sourceFile: sourceFile, searching: ShaderModules(sources: sources))
    if let result = try Tools.validate(shader) {
        #expect(result.isEmpty, "spirv-val: \(result)", sourceLocation: sourceLocation)
    }
    return SpirvWords(words: shader.spirv)
}

private func moduleError(_ source: String, _ sources: [String: String], contains needle: String, line: Int? = nil, file: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        _ = try PyShader.compile(source, target: .nucleant, sourceFile: nil, searching: ShaderModules(sources: sources))
        Issue.record("expected an error containing \"\(needle)\"", sourceLocation: sourceLocation)
    } catch let error as PyShaderError {
        #expect(error.message.contains(needle), "got: \(error)", sourceLocation: sourceLocation)
        if let line { #expect(error.line == line, "got line \(String(describing: error.line))", sourceLocation: sourceLocation) }
        #expect(error.file == file, "got file \(String(describing: error.file))", sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error type: \(error)", sourceLocation: sourceLocation)
    }
}

private let noise = """
    from pyshader import *

    SCALE = 2.0

    def hash(p: float2) -> float:
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453)

    def fbm(p: float2) -> float:
        return hash(p * SCALE) * 0.5 + hash(p) * 0.25

    def unused(p: float2) -> float:
        return no_such_function(p)
    """

@Suite("Modules")
struct ModuleTests {
    @Test("from x import name pulls in the function and what it uses, nothing else")
    func fromImport() throws {
        let words = try compileModules("""
            from pyshader import *
            from noise import fbm

            def hash(x: float) -> float:
                return x * 2.0

            def main(uv: float2) -> float4:
                return float4(fbm(uv), hash(uv.x), 0.0, 1.0)
            """, ["noise": noise])
        let n = names(words)
        #expect(n.contains("noise.fbm"))
        #expect(n.contains("noise.hash"))
        #expect(n.contains("hash"), "the shader's own `hash` is a different function")
        #expect(!n.contains("noise.unused"))
    }

    @Test("import x, import x as y and x.name reach functions, constants and classes")
    func moduleAccess() throws {
        let geometry = """
            class Ray:
                origin: float3
                direction: float3

            UP = float3(0.0, 1.0, 0.0)

            def at(r: Ray, t: float) -> float3:
                return r.origin + r.direction * t
            """
        let words = try compileModules("""
            import geometry
            import noise as n

            def main(uv: float2) -> float4:
                r: geometry.Ray = geometry.Ray(float3(uv, 0.0), geometry.UP)
                p = geometry.at(r, n.SCALE)
                return float4(p.xy, n.fbm(uv), geometry.UP.y)
            """, ["geometry": geometry, "noise": noise])
        let n = names(words)
        #expect(n.contains("geometry.Ray"))
        #expect(n.contains("geometry.at"))
        #expect(n.contains("noise.fbm"))
    }

    @Test("import * brings in only the names the code uses")
    func star() throws {
        let words = try compileModules("""
            from noise import *

            def main(uv: float2) -> float4:
                return float4(fbm(uv))
            """, ["noise": noise])
        let n = names(words)
        #expect(n.contains("noise.fbm"))
        #expect(!n.contains("noise.unused"))
    }

    @Test("__all__ limits import *; underscored names are private")
    func exports() {
        let lib = """
            __all__ = ["a"]
            def a() -> float:
                return 1.0
            def b() -> float:
                return 2.0
            """
        moduleError("from lib import *\ndef main(uv: float2) -> float4:\n    return float4(b())\n", ["lib": lib], contains: "unknown function `b`")
        moduleError("from lib import *\ndef main(uv: float2) -> float4:\n    return float4(_c())\n",
                    ["lib": "def _c() -> float:\n    return 1.0\n"], contains: "unknown function `_c`")
    }

    @Test("the shader's own names win over import *, and locals over globals")
    func scoping() throws {
        let words = try compileModules("""
            from noise import *

            def fbm(p: float2) -> float:
                return p.x

            def main(uv: float2) -> float4:
                hash = uv.y
                return float4(fbm(uv), hash, 0.0, 1.0)
            """, ["noise": noise])
        let n = names(words)
        #expect(!n.contains("noise.fbm"))
        #expect(!n.contains("noise.hash"))
    }

    @Test("packages: dotted imports, from-package imports, relative imports and re-exports")
    func packages() throws {
        let sources = [
            "shaderlib": "from .noise import fbm\n",
            "shaderlib.noise": "from .util import lerp\n\ndef fbm(p: float2) -> float:\n    return lerp(p.x, p.y, 0.5)\n",
            "shaderlib.util": "def lerp(a: float, b: float, t: float) -> float:\n    return a + (b - a) * t\n",
        ]
        for main in [
            "import shaderlib.noise\ndef main(uv: float2) -> float4:\n    return float4(shaderlib.noise.fbm(uv))\n",
            "from shaderlib import noise\ndef main(uv: float2) -> float4:\n    return float4(noise.fbm(uv))\n",
            "from shaderlib import fbm\ndef main(uv: float2) -> float4:\n    return float4(fbm(uv))\n",
            "from shaderlib.noise import fbm as f\ndef main(uv: float2) -> float4:\n    return float4(f(uv))\n",
        ] {
            let n = names(try compileModules(main, sources))
            #expect(n.contains("shaderlib.noise.fbm"), "\(main)")
            #expect(n.contains("shaderlib.util.lerp"), "\(main)")
        }
    }

    @Test("a module variable keeps its state across the module's functions")
    func moduleVariables() throws {
        let counter = """
            count = 0

            def tick() -> int:
                global count
                count += 1
                return count
            """
        let words = try compileModules("""
            import counter

            def main(uv: float2) -> float4:
                a = counter.tick()
                b = counter.tick()
                return float4(float(a + b + counter.count))
            """, ["counter": counter])
        #expect(names(words).contains("counter.count"))
        #expect(words.has(.opVariable))
    }

    @Test("a module's lambdas are instantiated per argument type")
    func lambdas() throws {
        let words = try compileModules("""
            from ops import sq

            def main(uv: float2) -> float4:
                return float4(sq(uv), sq(uv.x), 1.0)
            """, ["ops": "sq = lambda x: x * x\n"])
        #expect(names(words).filter { $0.hasPrefix("ops.sq") }.count == 2)
    }

    @Test("modules importing each other in a circle")
    func cycles() throws {
        try compileModules("""
            from a import f

            def main(uv: float2) -> float4:
                return float4(f(uv.x))
            """, [
                "a": "import b\n\ndef f(x: float) -> float:\n    return b.g(x) + 1.0\n\ndef h(x: float) -> float:\n    return x\n",
                "b": "import a\n\ndef g(x: float) -> float:\n    return a.h(x) * 2.0\n",
            ])
    }

    @Test("source lines: each imported file gets its OpString and OpLines")
    func sourceLines() throws {
        let words = try compileModules("""
            from noise import fbm

            def main(uv: float2) -> float4:
                return float4(fbm(uv))
            """, ["noise": noise], sourceFile: "main.py")
        #expect(strings(words) == ["main.py", "noise.py"])
        let noiseFile = words.instructions.first { $0.opcode == SpirvOp.opString.rawValue && string(Array($0.operands.dropFirst())) == "noise.py" }!.operands[0]
        let lines = words.instructions.filter { $0.opcode == SpirvOp.opLine.rawValue && $0.operands[0] == noiseFile }.map { $0.operands[1] }
        #expect(lines.contains(6), "hash's return")
        #expect(lines.contains(9), "fbm's return")
    }

    @Test("errors name the module file and its line")
    func errors() {
        let main = "from pyshader import *\nfrom noise import fbm\ndef main(uv: float2) -> float4:\n    return float4(fbm(uv))\n"
        moduleError("import math\ndef main(uv: float2) -> float4:\n    return float4(1.0)\n", [:], contains: "cannot import `math`", line: 1)
        moduleError(main, [:], contains: "no PyShader module named `noise`", line: 2)
        moduleError(main, ["noise": "def other() -> float:\n    return 1.0\n"], contains: "module `noise` has no `fbm`", line: 2)
        moduleError(main, ["noise": "import os\ndef fbm(p: float2) -> float:\n    return 1.0\n"], contains: "cannot import `os`", line: 1, file: "noise.py")
        moduleError(main, ["noise": "def fbm(p: float2) -> float:\n    x = 1.0\n    return nope(p)\n"], contains: "unknown function `nope`", line: 3, file: "noise.py")
        moduleError(main, ["noise": "print(1)\ndef fbm(p: float2) -> float:\n    return 1.0\n"], contains: "module-level expressions", line: 1, file: "noise.py")
        moduleError(main, ["noise": "def fbm(p: float2) -> float:\n    return 1.0\ndef fbm(p: float2) -> float:\n    return 2.0\n"], contains: "already defined", line: 3, file: "noise.py")
        moduleError("from a import *\nfrom b import *\ndef main(uv: float2) -> float4:\n    return float4(f())\n",
                    ["a": "def f() -> float:\n    return 1.0\n", "b": "def f() -> float:\n    return 2.0\n"], contains: "comes from both `a` and `b`", line: 4)
        moduleError("import noise\ndef main(uv: float2) -> float4:\n    return float4(noise)\n", ["noise": noise], contains: "not a value", line: 3)
        moduleError("from . import x\ndef main(uv: float2) -> float4:\n    return float4(1.0)\n", [:], contains: "relative import", line: 1)
        moduleError("from noise import fbm\ndef fbm(p: float2) -> float:\n    return 1.0\ndef main(uv: float2) -> float4:\n    return float4(1.0)\n",
                    ["noise": noise], contains: "both imported and defined", line: 1)
    }

    @Test("the modules example compiles from its folder and its library's source")
    func example() throws {
        let folder = examplesDirectory.appendingPathComponent("modules")
        let modules = ShaderModules(paths: [
            .init(directory: folder),
            .init(directory: folder.appendingPathComponent("packages/pyshader-noise/src")),
        ])
        let file = folder.appendingPathComponent("clouds.py")
        let shader = try PyShader.compile(String(contentsOf: file, encoding: .utf8), target: .nucleant, sourceFile: "clouds.py", searching: modules)
        if let result = try Tools.validate(shader) { #expect(result.isEmpty, "spirv-val: \(result)") }
        let words = SpirvWords(words: shader.spirv)
        let n = names(words)
        #expect(n.contains("noise.fbm.fbm"))
        #expect(n.contains("palettes.shade"))
        #expect(!n.contains("noise.hash.hash22"))
        #expect(!n.contains("palettes.unused_debug"))
        #expect(strings(words).contains("noise/fbm.py"))
    }

    @Test("the imports tutorial's example compiles: a module, named imports and a package's __all__")
    func importsExample() throws {
        let file = examplesDirectory.appendingPathComponent("imports/orbit.py")
        let shader = try PyShader.compile(contentsOf: file, target: .nucleantUI)
        if let result = try Tools.validate(shader) { #expect(result.isEmpty, "spirv-val: \(result)") }
        let n = names(SpirvWords(words: shader.spirv))
        for name in ["palette.ramp", "lighting.glow", "lighting.halo", "shapes.star.star", "shapes.ring.ring", "shapes.polar.angle_of"] {
            #expect(n.contains(name), "\(name)")
        }
    }
}

@Suite("Module discovery")
struct ModuleDiscoveryTests {
    /// A shader folder with a local module, inside a project whose `.venv`
    /// holds a declared shader library (installed, and one editable through
    /// a `.pth`) and an undeclared Python package.
    private func project() throws -> (root: URL, shader: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pyshader-modules-\(UUID().uuidString)")
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let site = ".venv/lib/python3.13/site-packages"
        try write("\(site)/noise/__init__.py", "def fbm(p: float2) -> float:\n    return p.x\n")
        try write("\(site)/pyshader_noise-0.1.0.dist-info/entry_points.txt", "[console_scripts]\nx = y:z\n\n[pyshader.modules]\nnoise = noise\n")
        try write("\(site)/numpy/__init__.py", "import sys\n")
        try write("\(site)/numpy-2.0.dist-info/METADATA", "Name: numpy\n")
        try write("\(site)/_editable_impl_colors.pth", "\(root.path)/colors-src/src\nimport _virtualenv\n")
        try write("\(site)/colors-0.1.0.dist-info/entry_points.txt", "[pyshader.modules]\ncolors = colors.palette:unused\n")
        try write("colors-src/src/colors/__init__.py", "RED = float3(1.0, 0.0, 0.0)\n")
        try write("shaders/local.py", "def half(x: float) -> float:\n    return x * 0.5\n")
        try write("shaders/main.py", "")
        return (root, root.appendingPathComponent("shaders/main.py"))
    }

    @Test("the script's folder, then the nearest .venv's declared packages, editable ones included")
    func discover() throws {
        let (root, shader) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let modules = ShaderModules.discover(near: shader, environment: [:])
        #expect(modules.paths.first?.directory.lastPathComponent == "shaders")
        #expect(modules.paths.first?.allowed == nil)
        #expect(modules.paths.dropFirst().allSatisfy { $0.allowed == Swift.Set(["noise", "colors.palette"]) })

        try "from noise import fbm\nfrom colors import RED\nimport local\ndef main(uv: float2) -> float4:\n    return float4(RED * local.half(fbm(uv)), 1.0)\n"
            .write(to: shader, atomically: true, encoding: .utf8)
        let words = SpirvWords(words: try PyShader.compile(contentsOf: shader, target: .nucleant).spirv)
        #expect(names(words).contains("noise.fbm"))
        #expect(names(words).contains("local.half"))
    }

    @Test("a shader with no .venv above it compiles: the search stops at the root")
    func noVenv() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pyshader-novenv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shader = root.appendingPathComponent("main.py")
        try "def main(uv: float2) -> float4:\n    return float4(uv, 0.0, 1.0)\n".write(to: shader, atomically: true, encoding: .utf8)
        // A folder URL ends in `/`; walking up from one reaches `file:///`.
        #expect(ShaderModules.nearestVenv(from: root) == nil)
        #expect(ShaderModules.discover(near: shader, environment: [:]).paths.count == 1)
        _ = try PyShader.compile(contentsOf: shader, target: .nucleant)
    }

    @Test("an installed package that declares no pyshader.modules entry point cannot be imported")
    func undeclared() throws {
        let (root, shader) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        try "import numpy\ndef main(uv: float2) -> float4:\n    return float4(1.0)\n".write(to: shader, atomically: true, encoding: .utf8)
        do {
            _ = try PyShader.compile(contentsOf: shader, target: .nucleant)
            Issue.record("expected an error")
        } catch let error as PyShaderError {
            #expect(error.message.contains("`numpy/__init__.py` is installed but is not a PyShader module"), "got: \(error)")
            #expect(error.line == 1)
        }
    }

    @Test("a library installed under pyshader (pyshader.stdlib): imported in every form, next to the builtins", arguments: [false, true])
    func underPyshader(editable: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pyshader-stdlib-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let site = ".venv/lib/python3.13/site-packages"
        // The editor stubs: never read by the compiler, and nothing beside `stdlib` under them is importable.
        try write("\(site)/pyshader/__init__.py", "from typing import Any\n")
        try write("\(site)/pyshader/secret.py", "X = 1.0\n")
        try write("\(site)/pyshader-0.1.0.dist-info/METADATA", "Name: pyshader\n")
        try write("\(site)/pyshader_stdlib-0.1.0.dist-info/entry_points.txt", "[pyshader.modules]\nstdlib = pyshader.stdlib\n")
        // Installed, the library's files join the stubs' folder; editable, a `.pth` points at its source.
        let library = editable ? "stdlib-src/src" : site
        if editable { try write("\(site)/_pyshader_stdlib.pth", "\(root.path)/stdlib-src/src\n") }
        try write("\(library)/pyshader/stdlib/__init__.py", "\"\"\"The library.\"\"\"\n")
        try write("\(library)/pyshader/stdlib/fragment/__init__.py", "")
        try write("\(library)/pyshader/stdlib/fragment/shapes.py", "from pyshader import *\nfrom .matrix import rotate2d\n\ndef circle(p: float2, r: float) -> float:\n    return step(length(rotate2d(PI) * p), r)\n")
        try write("\(library)/pyshader/stdlib/fragment/matrix.py", "from pyshader import *\n\ndef rotate2d(a: float) -> float2x2:\n    return float2x2(cos(a), sin(a), -sin(a), cos(a))\n")
        try write("shaders/main.py", "")
        let shader = root.appendingPathComponent("shaders/main.py")

        for source in [
            "from pyshader import *\nfrom pyshader.stdlib.fragment.shapes import circle\ndef main(uv: float2) -> float4:\n    return float4(circle(uv, 0.5))\n",
            "from pyshader import *\nfrom pyshader.stdlib.fragment import shapes\ndef main(uv: float2) -> float4:\n    return float4(shapes.circle(uv, 0.5))\n",
            "import pyshader.stdlib.fragment.shapes as shapes\ndef main(uv: float2) -> float4:\n    return float4(shapes.circle(uv, 0.5))\n",
            "import pyshader\nimport pyshader.stdlib.fragment.shapes\ndef main(uv: pyshader.float2) -> pyshader.float4:\n    return pyshader.float4(pyshader.stdlib.fragment.shapes.circle(uv, pyshader.sin(0.5)))\n",
        ] {
            try source.write(to: shader, atomically: true, encoding: .utf8)
            let compiled = try PyShader.compile(contentsOf: shader, target: .nucleant)
            if let result = try Tools.validate(compiled) { #expect(result.isEmpty, "spirv-val: \(result)") }
            let n = names(SpirvWords(words: compiled.spirv))
            #expect(n.contains("pyshader.stdlib.fragment.shapes.circle"), "\(source)")
            #expect(n.contains("pyshader.stdlib.fragment.matrix.rotate2d"), "\(source)")
        }

        try "from pyshader.secret import X\ndef main(uv: float2) -> float4:\n    return float4(X)\n".write(to: shader, atomically: true, encoding: .utf8)
        do {
            _ = try PyShader.compile(contentsOf: shader, target: .nucleant)
            Issue.record("expected an error")
        } catch let error as PyShaderError {
            #expect(error.message.contains("`pyshader/secret.py` is installed but is not a PyShader module"), "got: \(error)")
        }
    }

    @Test("modules: handed over as sources, packages under pyshader included")
    func moduleSources() throws {
        let sources = [
            "pyshader.stdlib": "",
            "pyshader.stdlib.fragment": "",
            "pyshader.stdlib.fragment.sdf": "from pyshader import *\n\ndef sd_circle(p: float2, r: float) -> float:\n    return length(p) - r\n",
            "palettes": "SUNSET = float3(1.0, 0.5, 0.2)\n",
        ]
        let shader = try PyShader.compile("""
            from pyshader import *
            from pyshader.stdlib.fragment.sdf import sd_circle
            import palettes
            def main(uv: float2) -> float4:
                return float4(palettes.SUNSET * sd_circle(uv - 0.5, 0.3), 1.0)
            """, target: .nucleant, modules: sources)
        let n = names(SpirvWords(words: shader.spirv))
        #expect(n.contains("pyshader.stdlib.fragment.sdf.sd_circle"))
        #expect(throws: PyShaderError.self) {
            try PyShader.compile("import palettes\ndef main(uv: float2) -> float4:\n    return float4(1.0)\n", target: .nucleant, modules: [String: String]())
        }
    }

    @Test("modules: names the site-packages folder, as a URL or a path")
    func sitePackagesArgument() throws {
        let (root, shader) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let site = root.appendingPathComponent(".venv/lib/python3.13/site-packages")
        let source = "from noise import fbm\nfrom colors import RED\ndef main(uv: float2) -> float4:\n    return float4(RED * fbm(uv), 1.0)\n"
        let byURL = try PyShader.compile(source, target: .nucleant, modules: site)
        let byPath = try PyShader.compile(source, target: .nucleant, modules: site.path)
        #expect(byURL.spirv == byPath.spirv)
        #expect(names(SpirvWords(words: byURL.spirv)).contains("noise.fbm"))

        // Without it, only `pyshader` can be imported.
        #expect(throws: PyShaderError.self) { try PyShader.compile(source, target: .nucleant) }

        // A file takes the given folder instead of its nearest .venv; its own folder still comes first.
        try "import local\n\(source)".write(to: shader, atomically: true, encoding: .utf8)
        let other = root.appendingPathComponent("empty-site")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(throws: PyShaderError.self) { try PyShader.compile(contentsOf: shader, target: .nucleant, modules: other.path) }
        _ = try PyShader.compile(contentsOf: shader, target: .nucleant, modules: site)
    }
}
