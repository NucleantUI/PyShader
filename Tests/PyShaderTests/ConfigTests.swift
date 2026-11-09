import Foundation
import Testing
@testable import PyShaderConfig

@Suite("pyshader.toml")
struct ConfigTests {
    @Test("sections, defaults and the general site-packages")
    func parse() throws {
        let config = try PyShaderConfig(parsing: """
            # shaders of this package
            site-packages = ".venv/lib/python3.13/site-packages"

            [clouds]
            source = "Shaders/clouds.py"   # a comment
            output = 'Resources/clouds.spv'
            target = "compute"
            content = true
            arguments = [
                "gain:float",   # one per line
                "tint:float4",
            ]
            optimize = ["-O", "--strip-debug"]

            ["plain.name"]
            source = "Shaders/#plasma.py"

            [upright]
            source = "Shaders/upright.py"
            content-top-down = true
            """)
        #expect(config.sitePackages == ".venv/lib/python3.13/site-packages")
        #expect(config.sections == [
            .init(name: "clouds", source: "Shaders/clouds.py", output: "Resources/clouds.spv", target: "compute", content: true, arguments: ["gain:float", "tint:float4"], optimize: ["-O", "--strip-debug"]),
            .init(name: "plain.name", source: "Shaders/#plasma.py", output: "plain.name.spv", target: "fragment", content: false, arguments: [], optimize: []),
            .init(name: "upright", source: "Shaders/upright.py", output: "upright.spv", target: "fragment", content: true, arguments: [], optimize: [], contentIsTopDown: true),
        ])
    }

    @Test("pyshaderc's arguments for a section")
    func compilerArguments() throws {
        let config = try PyShaderConfig(parsing: "site-packages = \"site\"\n[a]\nsource = \"s/a.py\"\ntarget = \"graphics\"\ncontent = true\narguments = [\"t:floatArray\"]\noptimize = [\"-O\", \"--strip-debug\"]\n")
        let root = URL(fileURLWithPath: "/pkg")
        #expect(config.compilerArguments(for: config.sections[0], root: root, output: URL(fileURLWithPath: "/out/a.spv")) == [
            "/pkg/s/a.py", "-o", "/out/a.spv", "--target", "graphics", "--content", "--arg", "t:floatArray",
            "--optimize", "-O", "--optimize", "--strip-debug", "--site-packages", "/pkg/site",
        ])
        let topDown = try PyShaderConfig(parsing: "[b]\nsource = \"b.py\"\ntarget = \"compute\"\ncontent = true\ncontent-top-down = true\n")
        #expect(topDown.compilerArguments(for: topDown.sections[0], root: root, output: URL(fileURLWithPath: "/out/b.spv")) == [
            "/pkg/b.py", "-o", "/out/b.spv", "--target", "compute", "--content-top-down",
        ])
    }

    @Test("format = \"gles2\": an OpenGL ES 2 .glsl, by default <section>.glsl")
    func gles2Format() throws {
        let config = try PyShaderConfig(parsing: "[es]\nsource = \"k.py\"\ntarget = \"compute\"\nformat = \"gles2\"\n[vk]\nsource = \"v.py\"\nformat = \"spirv\"\n")
        #expect(config.sections[0].format == "gles2")
        #expect(config.sections[0].outputs == ["es.vert", "es.frag"])
        #expect(config.sections[1].outputs == ["vk.spv"])
        let root = URL(fileURLWithPath: "/pkg")
        #expect(config.compilerArguments(for: config.sections[0], root: root, output: URL(fileURLWithPath: "/out/es")) == [
            "/pkg/k.py", "-o", "/out/es", "--target", "compute", "--format", "gles2",
        ])
        #expect(!config.compilerArguments(for: config.sections[1], root: root, output: URL(fileURLWithPath: "/out/vk.spv")).contains("--format"))
    }

    @Test("the gles2 names, matrices and single file are pyshaderc's flags")
    func gles2Options() throws {
        let config = try PyShaderConfig(parsing: """
            [fx]
            source = "fx.py"
            output = "Shaders/fx.glsl"
            format = "gles2"
            single-file = true
            uv-top-down = true
            uv-varying = "tex_coord0"
            content-sampler = "texture0"
            position-matrices = ["projection_mat", "modelview_mat"]
            [two]
            source = "t.py"
            output = "Shaders/two.glsl"
            format = "gles2"
            """)
        #expect(config.sections[0].outputs == ["Shaders/fx.glsl"])
        #expect(config.sections[1].outputs == ["Shaders/two.vert", "Shaders/two.frag"])
        #expect(config.compilerArguments(for: config.sections[0], root: URL(fileURLWithPath: "/pkg"), output: URL(fileURLWithPath: "/out/fx.glsl")) == [
            "/pkg/fx.py", "-o", "/out/fx.glsl", "--target", "fragment", "--format", "gles2", "--single-file",
            "--uv-top-down", "--uv-varying", "tex_coord0", "--content-sampler", "texture0",
            "--position-matrix", "projection_mat", "--position-matrix", "modelview_mat",
        ])
    }

    @Test("textures-top-down reads the Texture parameters top-down")
    func texturesTopDown() throws {
        let config = try PyShaderConfig(parsing: "[fx]\nsource = \"fx.py\"\ntarget = \"compute\"\ntextures-top-down = true\n[plain]\nsource = \"p.py\"\n")
        #expect(config.sections[0].texturesAreTopDown)
        #expect(!config.sections[1].texturesAreTopDown)
        let root = URL(fileURLWithPath: "/pkg")
        #expect(config.compilerArguments(for: config.sections[0], root: root, output: URL(fileURLWithPath: "/out/fx.spv")) == [
            "/pkg/fx.py", "-o", "/out/fx.spv", "--target", "compute", "--textures-top-down",
        ])
        #expect(!config.compilerArguments(for: config.sections[1], root: root, output: URL(fileURLWithPath: "/out/plain.spv")).contains("--textures-top-down"))
    }

    @Test("mistakes are reported with their line")
    func errors() {
        func expectError(_ text: String, _ needle: String, line: Int, sourceLocation: SourceLocation = #_sourceLocation) {
            do {
                _ = try PyShaderConfig(parsing: text)
                Issue.record("expected an error containing \"\(needle)\"", sourceLocation: sourceLocation)
            } catch let error as PyShaderConfig.ParseError {
                #expect(error.message.contains(needle), "got: \(error)", sourceLocation: sourceLocation)
                #expect(error.line == line, "got line \(error.line)", sourceLocation: sourceLocation)
            } catch {
                Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
            }
        }
        expectError("", "no sections", line: 1)
        expectError("[a]\noutput = \"a.spv\"\n", "needs `source", line: 1)
        expectError("[a]\nsource = \"a.py\"\ntarget = \"vertex\"\n", "`target` is one of", line: 3)
        expectError("[a]\nsource = \"a.py\"\nsoruce = \"b.py\"\n", "unknown key `soruce`", line: 3)
        expectError("[a]\nsource = \"a.py\"\nformat = \"glsl\"\n", "`format` is one of spirv, gles2", line: 3)
        expectError("[a]\nsource = \"a.py\"\noptimize = [\"-O\"]\nformat = \"gles2\"\n", "does not apply", line: 3)
        expectError("output = \"x\"\n[a]\nsource = \"a.py\"\n", "only `site-packages`", line: 1)
        expectError("[a]\nsource = \"a.py\"\n[a]\nsource = \"b.py\"\n", "defined twice", line: 3)
        expectError("[a]\nsource = \"a.py\"\narguments = [\"gain\"]\n", "name:kind", line: 3)
        expectError("[a]\nsource = \"a.py\"\ncontent = \"yes\"\n", "`true` or `false`", line: 3)
        expectError("[a]\nsource = \"a.py\"\ncontent-top-down = \"yes\"\n", "`content-top-down` must be", line: 3)
        expectError("[a]\nsource = \"a.py\"\ntextures-top-down = \"yes\"\n", "`textures-top-down` must be", line: 3)
        expectError("[a]\nsource = \"a.py\"\nuv-varying = \"v\"\n", "applies to `format = \"gles2\"`", line: 3)
        expectError("[a]\nsource = \"a.py\"\nformat = \"gles2\"\nposition-matrices = \"m\"\n", "array of uniform names", line: 4)
        expectError("[a]\nsource = \"a.py\"\nformat = \"gles2\"\noutput = \"x.glsl\"\n[b]\nsource = \"b.py\"\nformat = \"gles2\"\noutput = \"x.frag\"\n", "two sections write `x.vert`", line: 1)
        expectError("[a]\nsource = \"a.py\"\noptimize = \"-O\"\n", "`optimize` must be an array", line: 3)
        expectError("[a]\nsource = \"a.py\"\noptimize = [\"O\"]\n", "must start with `-`", line: 3)
        expectError("[a]\nsource = a.py\n", "expected a string", line: 2)
        expectError("[a.b]\nsource = \"a.py\"\n", "one name", line: 1)
        expectError("[a]\nsource = \"a.py\"\n[b]\nsource = \"b.py\"\noutput = \"a.spv\"\n", "two sections write `a.spv`", line: 1)
    }

    @Test("inputs: the source's folder and the declared packages of site-packages, editable ones included")
    func inputFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pyshader-config-\(UUID().uuidString)").standardizedFileURL
        defer { try? fm.removeItem(at: root) }
        func write(_ path: String, _ text: String = "") throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("Shaders/main.py")
        try write("Shaders/lib/shapes.py")
        try write("Shaders/notes.txt")
        let site = ".venv/lib/python3.13/site-packages"
        try write("\(site)/noise/__init__.py")
        try write("\(site)/numpy/__init__.py")
        try write("editable/src/colors/palette.py")
        try write("\(site)/noise-0.1.dist-info/entry_points.txt", "[pyshader.modules]\nnoise = noise\n")
        try write("\(site)/colors-0.1.dist-info/entry_points.txt", "[pyshader.modules]\ncolors = colors\n")
        try write("\(site)/_colors.pth", "\(root.path)/editable/src\n")

        // A library under `pyshader` counts; the `pyshader` stubs beside it do not.
        try write("\(site)/pyshader/__init__.py")
        try write("\(site)/pyshader/stdlib/__init__.py")
        try write("\(site)/pyshader/stdlib/fragment/noise.py")
        try write("\(site)/pyshader_stdlib-0.1.dist-info/entry_points.txt", "[pyshader.modules]\nstdlib = pyshader.stdlib\n")

        let configFile = root.appendingPathComponent("pyshader.toml")
        for text in ["[a]\nsource = \"Shaders/main.py\"\n", "site-packages = \"\(site)\"\n[a]\nsource = \"Shaders/main.py\"\n"] {
            let config = try PyShaderConfig(parsing: text)
            let inputs = config.inputFiles(for: config.sections[0], root: root, configFile: configFile).map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
            #expect(inputs.sorted() == [
                ".venv/lib/python3.13/site-packages/noise/__init__.py",
                ".venv/lib/python3.13/site-packages/pyshader/stdlib/__init__.py",
                ".venv/lib/python3.13/site-packages/pyshader/stdlib/fragment/noise.py",
                "Shaders/lib/shapes.py",
                "Shaders/main.py",
                "editable/src/colors/palette.py",
                "pyshader.toml",
            ], "\(text)")
        }
    }

    @Test("the .venv search stops at the root when there is none above")
    func noVenv() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pyshader-config-novenv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(PyShaderConfig.nearestVenv(from: root) == nil)
    }
}
