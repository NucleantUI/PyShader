//
//  PyShaderConfig.swift
//  PyShaderConfig
//
//  `pyshader.toml`: which PyShader files a package compiles to SPIR-V, and
//  how. Read by `pyshaderc --config` and by the package plugins, which find
//  it at the root of the package.
//
//      site-packages = ".venv/lib/python3.12/site-packages"   # optional, for every section
//
//      [clouds]
//      source = "Shaders/clouds.py"
//      output = "Resources/clouds.spv"      # optional: <section>.spv
//      target = "compute"                   # optional: fragment | compute | graphics
//      content = true                       # optional
//      arguments = ["gain:float", "tint:float4"]
//
//  Paths are relative to the folder the file is in. Only the TOML this needs
//  is read: tables, and keys holding strings, booleans or arrays of strings.
//
//  Foundation only: this file is also compiled into the plugins, which can
//  depend on nothing else.
//

import Foundation

struct PyShaderConfig: Equatable {
    /// One `[name]` table: a source file and the SPIR-V file it becomes.
    struct Section: Equatable {
        let name: String
        let source: String
        let output: String
        let target: String
        let content: Bool
        let arguments: [String]
    }

    /// The file's name, at the root of the package.
    static let fileName = "pyshader.toml"
    static let targets = ["fragment", "compute", "graphics"]

    /// The general `site-packages`, when given.
    let sitePackages: String?
    let sections: [Section]

    struct ParseError: Error, CustomStringConvertible {
        let message: String
        let line: Int
        var description: String { "\(PyShaderConfig.fileName), line \(line): \(message)" }
    }

    init(sitePackages: String?, sections: [Section]) {
        self.sitePackages = sitePackages
        self.sections = sections
    }

    init(contentsOf url: URL) throws {
        try self.init(parsing: String(contentsOf: url, encoding: .utf8))
    }

    init(parsing text: String) throws {
        enum Value { case string(String), bool(Bool), strings([String]) }
        var top: [String: (Value, Int)] = [:]
        var tables: [(name: String, line: Int, keys: [String: (Value, Int)])] = []

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let number = i + 1
            var line = Self.stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
                    throw ParseError(message: "a table header is `[name]`", line: number)
                }
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                let unquoted = name.count >= 2 && name.first == "\"" && name.last == "\"" ? String(name.dropFirst().dropLast()) : name
                guard !unquoted.isEmpty, !unquoted.contains(".") || name.first == "\"" else {
                    throw ParseError(message: "`[\(name)]`: a section is one name, not a dotted path", line: number)
                }
                if tables.contains(where: { $0.name == unquoted }) {
                    throw ParseError(message: "section `\(unquoted)` is defined twice", line: number)
                }
                tables.append((unquoted, number, [:]))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                throw ParseError(message: "expected `key = value`", line: number)
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // An array may continue over several lines until its `]`.
            if raw.hasPrefix("[") {
                while !Self.closesArray(raw), i < lines.count {
                    raw += " " + Self.stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
                    i += 1
                }
            }
            line = raw
            let value: Value
            if line == "true" {
                value = .bool(true)
            } else if line == "false" {
                value = .bool(false)
            } else if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw ParseError(message: "`\(key)`: unterminated array", line: number) }
                var items: [String] = []
                var rest = Substring(line.dropFirst().dropLast())
                while true {
                    rest = rest.drop(while: { $0 == " " || $0 == "\t" })
                    if rest.isEmpty { break }
                    guard let (string, after) = Self.string(rest) else {
                        throw ParseError(message: "`\(key)`: an array holds strings", line: number)
                    }
                    items.append(string)
                    rest = after.drop(while: { $0 == " " || $0 == "\t" })
                    if rest.first == "," { rest = rest.dropFirst() } else if !rest.isEmpty {
                        throw ParseError(message: "`\(key)`: expected `,` between items", line: number)
                    }
                }
                value = .strings(items)
            } else if let (string, after) = Self.string(Substring(line)), after.allSatisfy(\.isWhitespace) {
                value = .string(string)
            } else {
                throw ParseError(message: "`\(key)`: expected a string, `true` / `false` or an array of strings", line: number)
            }
            if tables.isEmpty {
                guard top[key] == nil else { throw ParseError(message: "`\(key)` is set twice", line: number) }
                top[key] = (value, number)
            } else {
                guard tables[tables.count - 1].keys[key] == nil else { throw ParseError(message: "`\(key)` is set twice", line: number) }
                tables[tables.count - 1].keys[key] = (value, number)
            }
        }

        func string(_ keys: [String: (Value, Int)], _ key: String, in owner: String) throws -> String? {
            guard let (value, line) = keys[key] else { return nil }
            guard case .string(let s) = value else { throw ParseError(message: "\(owner)`\(key)` must be a string", line: line) }
            return s
        }

        for (key, (_, line)) in top where key != "site-packages" {
            throw ParseError(message: "unknown key `\(key)`; outside a section only `site-packages` is set", line: line)
        }
        let sitePackages = try string(top, "site-packages", in: "")

        var sections: [Section] = []
        for table in tables {
            let owner = "[\(table.name)] "
            for (key, (_, line)) in table.keys where !["source", "output", "target", "content", "arguments"].contains(key) {
                throw ParseError(message: "\(owner)unknown key `\(key)`", line: line)
            }
            guard let source = try string(table.keys, "source", in: owner) else {
                throw ParseError(message: "\(owner)needs `source = \"path/to/shader.py\"`", line: table.line)
            }
            let target = try string(table.keys, "target", in: owner) ?? "fragment"
            guard Self.targets.contains(target) else {
                throw ParseError(message: "\(owner)`target` is one of \(Self.targets.joined(separator: ", ")), not `\(target)`", line: table.keys["target"]!.1)
            }
            var content = false
            if let (value, line) = table.keys["content"] {
                guard case .bool(let b) = value else { throw ParseError(message: "\(owner)`content` must be `true` or `false`", line: line) }
                content = b
            }
            var arguments: [String] = []
            if let (value, line) = table.keys["arguments"] {
                guard case .strings(let a) = value else { throw ParseError(message: "\(owner)`arguments` must be an array of `\"name:kind\"`", line: line) }
                for argument in a where argument.split(separator: ":").count != 2 {
                    throw ParseError(message: "\(owner)argument `\(argument)` must be `\"name:kind\"`", line: line)
                }
                arguments = a
            }
            let output = try string(table.keys, "output", in: owner) ?? "\(table.name).spv"
            sections.append(Section(name: table.name, source: source, output: output, target: target, content: content, arguments: arguments))
        }
        guard !sections.isEmpty else {
            throw ParseError(message: "no sections: add a `[name]` table with a `source` for each shader", line: 1)
        }
        let outputs = sections.map(\.output)
        if let duplicate = outputs.first(where: { o in outputs.filter { $0 == o }.count > 1 }) {
            throw ParseError(message: "two sections write `\(duplicate)`", line: 1)
        }
        self.init(sitePackages: sitePackages, sections: sections)
    }

    /// `pyshaderc`'s arguments for a section, `root` being the config file's folder.
    func compilerArguments(for section: Section, root: URL, output: URL) -> [String] {
        var args = [root.appendingPathComponent(section.source).path, "-o", output.path, "--target", section.target]
        if section.content { args.append("--content") }
        for argument in section.arguments { args += ["--arg", argument] }
        if let sitePackages { args += ["--site-packages", root.appendingPathComponent(sitePackages).path] }
        return args
    }

    // MARK: - Inputs

    /// Every file a section's build reads, for a build system to rerun it when
    /// one changes: the config, each `.py` file beside the source and below
    /// its folder (local modules), and the `.py` files of the PyShader
    /// packages in the site-packages folder it uses — the given one, or the
    /// nearest `.venv`'s above the source.
    func inputFiles(for section: Section, root: URL, configFile: URL) -> [URL] {
        let source = root.appendingPathComponent(section.source).standardizedFileURL
        var files = [configFile, source]
        files += Self.pythonFiles(under: source.deletingLastPathComponent())
        let sites: [URL]
        if let sitePackages {
            sites = [root.appendingPathComponent(sitePackages).standardizedFileURL]
        } else if let venv = Self.nearestVenv(from: source.deletingLastPathComponent()) {
            sites = Self.sitePackages(in: venv)
        } else {
            sites = []
        }
        for site in sites { files += Self.moduleFiles(inSitePackages: site) }
        var seen: Set<String> = []
        return files.filter { seen.insert($0.path).inserted }
    }

    /// The `.py` files of the packages a site-packages folder declares under
    /// the `pyshader.modules` entry point, editable installs (`.pth`) included.
    static func moduleFiles(inSitePackages site: URL) -> [URL] {
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(atPath: site.path)) ?? []).sorted()
        var declared: [String] = []
        var folders = [site]
        for entry in entries {
            let url = site.appendingPathComponent(entry)
            if entry.hasSuffix(".dist-info"), let text = try? String(contentsOf: url.appendingPathComponent("entry_points.txt"), encoding: .utf8) {
                declared += declaredModules(entryPoints: text)
            } else if entry.hasSuffix(".pth"), let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(whereSeparator: \.isNewline) {
                    let path = line.trimmingCharacters(in: .whitespaces)
                    if path.isEmpty || path.hasPrefix("#") || path.hasPrefix("import ") || path.hasPrefix("import\t") { continue }
                    folders.append(path.hasPrefix("/") ? URL(fileURLWithPath: path) : site.appendingPathComponent(path))
                }
            }
        }
        var files: [URL] = []
        for folder in folders {
            for module in declared {
                let file = folder.appendingPathComponent(module + ".py")
                if fm.fileExists(atPath: file.path) { files.append(file) }
                files += pythonFiles(under: folder.appendingPathComponent(module))
            }
        }
        return files
    }

    /// The top-level packages an `entry_points.txt`'s `[pyshader.modules]` section names.
    static func declaredModules(entryPoints text: String) -> [String] {
        var modules: [String] = []
        var inSection = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = line == "[pyshader.modules]"; continue }
            guard inSection, let eq = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let top = value.split(separator: ":").first?.split(separator: ".").first, !modules.contains(String(top)) {
                modules.append(String(top))
            }
        }
        return modules
    }

    static func pythonFiles(under folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "py" {
            files.append(url.standardizedFileURL)
        }
        return files.sorted { $0.path < $1.path }
    }

    static func nearestVenv(from folder: URL) -> URL? {
        var dir = folder.standardizedFileURL
        while true {
            let venv = dir.appendingPathComponent(".venv")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: venv.path, isDirectory: &isDir), isDir.boolValue { return venv }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    static func sitePackages(in venv: URL) -> [URL] {
        let lib = venv.appendingPathComponent("lib")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: lib.path))?.filter { $0.hasPrefix("python") }.sorted() ?? []
        return versions.map { lib.appendingPathComponent($0).appendingPathComponent("site-packages") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Lexing

    /// The line without a trailing `# comment` (a `#` inside a string stays).
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for (offset, c) in line.enumerated() {
            if let q = quote {
                if escaped { escaped = false } else if c == "\\" && q == "\"" { escaped = true } else if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                return String(line.prefix(offset))
            }
        }
        return line
    }

    private static func closesArray(_ text: String) -> Bool {
        text.hasSuffix("]")
    }

    /// A basic (`"..."`, with escapes) or literal (`'...'`) string at the start of `text`, and what follows it.
    private static func string(_ text: Substring) -> (String, Substring)? {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
        var out = ""
        var i = text.index(after: text.startIndex)
        while i < text.endIndex {
            let c = text[i]
            if c == quote { return (out, text[text.index(after: i)...]) }
            if c == "\\" && quote == "\"" {
                i = text.index(after: i)
                guard i < text.endIndex else { return nil }
                switch text[i] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                default: return nil
                }
            } else {
                out.append(c)
            }
            i = text.index(after: i)
        }
        return nil
    }
}
