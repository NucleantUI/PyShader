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

            ["plain.name"]
            source = "Shaders/#plasma.py"
            """)
        #expect(config.sitePackages == ".venv/lib/python3.13/site-packages")
        #expect(config.sections == [
            .init(name: "clouds", source: "Shaders/clouds.py", output: "Resources/clouds.spv", target: "compute", content: true, arguments: ["gain:float", "tint:float4"]),
            .init(name: "plain.name", source: "Shaders/#plasma.py", output: "plain.name.spv", target: "fragment", content: false, arguments: []),
        ])
    }

    @Test("pyshaderc's arguments for a section")
    func compilerArguments() throws {
        let config = try PyShaderConfig(parsing: "site-packages = \"site\"\n[a]\nsource = \"s/a.py\"\ntarget = \"graphics\"\ncontent = true\narguments = [\"t:floatArray\"]\n")
        let root = URL(fileURLWithPath: "/pkg")
        #expect(config.compilerArguments(for: config.sections[0], root: root, output: URL(fileURLWithPath: "/out/a.spv")) == [
            "/pkg/s/a.py", "-o", "/out/a.spv", "--target", "graphics", "--content", "--arg", "t:floatArray", "--site-packages", "/pkg/site",
        ])
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
        expectError("output = \"x\"\n[a]\nsource = \"a.py\"\n", "only `site-packages`", line: 1)
        expectError("[a]\nsource = \"a.py\"\n[a]\nsource = \"b.py\"\n", "defined twice", line: 3)
        expectError("[a]\nsource = \"a.py\"\narguments = [\"gain\"]\n", "name:kind", line: 3)
        expectError("[a]\nsource = \"a.py\"\ncontent = \"yes\"\n", "`true` or `false`", line: 3)
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
}
