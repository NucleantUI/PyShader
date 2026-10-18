//
//  ShaderModules.swift
//  PyShader
//
//  Where `import` finds PyShader modules: sources handed over in memory,
//  plain folders (the shader's own, `--module-path`, `PYSHADER_PATH`), and a
//  uv environment's site-packages, where only the packages that declare a
//  `pyshader.modules` entry point count.
//

import Foundation

/// The places a shader's imports are looked up, in order.
public struct ShaderModules: Sendable {
    /// One folder modules are looked up in, like an entry of Python's `sys.path`.
    public struct SearchPath: Sendable, Equatable {
        public let directory: URL
        /// The top-level packages importable from here; nil for any. A
        /// site-packages folder holds every Python package of the
        /// environment, so only the ones whose distribution declares a
        /// `pyshader.modules` entry point are let through.
        public let allowed: Swift.Set<String>?

        public init(directory: URL, allowed: Swift.Set<String>? = nil) {
            self.directory = directory
            self.allowed = allowed
        }
    }

    /// Module sources by dotted name (`"noise"`, `"shaderlib.noise"`); a
    /// package's own source is its `__init__.py`. Looked up before `paths`.
    public var sources: [String: String]
    public var paths: [SearchPath]

    public init(sources: [String: String] = [:], paths: [SearchPath] = []) {
        self.sources = sources
        self.paths = paths
    }

    /// Nothing to import from: any import besides `pyshader` is an error.
    public static let none = ShaderModules()

    /// What a shader file on disk imports from, like Python's `sys.path`:
    /// the file's own folder, `extraPaths`, each folder of `PYSHADER_PATH`,
    /// and the site-packages of the nearest `.venv` above the file (or of
    /// `VIRTUAL_ENV` when there is none) — where `uv add` installs a
    /// shader library.
    public static func discover(near file: URL, extraPaths: [URL] = [], environment: [String: String] = ProcessInfo.processInfo.environment) -> ShaderModules {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        var paths = [SearchPath(directory: folder)]
        paths += extraPaths.map { SearchPath(directory: $0.standardizedFileURL) }
        if let list = environment["PYSHADER_PATH"] {
            paths += list.split(separator: ":").map { SearchPath(directory: URL(fileURLWithPath: String($0)).standardizedFileURL) }
        }
        let venv = nearestVenv(from: folder) ?? environment["VIRTUAL_ENV"].map { URL(fileURLWithPath: $0) }
        if let venv {
            for site in sitePackages(in: venv) { paths += searchPaths(forSitePackages: site) }
        }
        return ShaderModules(paths: paths)
    }

    /// The first `.venv` folder in `folder` or above it.
    static func nearestVenv(from folder: URL) -> URL? {
        var dir = folder
        while true {
            let venv = dir.appendingPathComponent(".venv")
            if isDirectory(venv) { return venv }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    /// `lib/python3.X/site-packages` (`Lib/site-packages` on Windows).
    static func sitePackages(in venv: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        let lib = venv.appendingPathComponent("lib")
        let versions = (try? fm.contentsOfDirectory(atPath: lib.path))?.filter { $0.hasPrefix("python") }.sorted() ?? []
        for version in versions {
            let site = lib.appendingPathComponent(version).appendingPathComponent("site-packages")
            if isDirectory(site) { found.append(site) }
        }
        let windows = venv.appendingPathComponent("Lib").appendingPathComponent("site-packages")
        if found.isEmpty, isDirectory(windows) { found.append(windows) }
        return found
    }

    /// A site-packages folder and the folders its `.pth` files add (an
    /// editable install, `uv add --editable`, leaves its source where it is
    /// and points there), each letting through only the packages the
    /// environment's distributions declare as PyShader modules.
    public static func searchPaths(forSitePackages site: URL) -> [SearchPath] {
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(atPath: site.path)) ?? []).sorted()
        var allowed: Swift.Set<String> = []
        var folders = [site]
        for entry in entries {
            let url = site.appendingPathComponent(entry)
            if entry.hasSuffix(".dist-info") {
                let points = url.appendingPathComponent("entry_points.txt")
                if let text = try? String(contentsOf: points, encoding: .utf8) {
                    allowed.formUnion(declaredModules(entryPoints: text))
                }
            } else if entry.hasSuffix(".pth"), let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(whereSeparator: \.isNewline) {
                    let path = line.trimmingCharacters(in: .whitespaces)
                    // Comments and `import ...` lines (code run at startup) add no folder.
                    if path.isEmpty || path.hasPrefix("#") || path.hasPrefix("import ") || path.hasPrefix("import\t") { continue }
                    let folder = path.hasPrefix("/") ? URL(fileURLWithPath: path) : site.appendingPathComponent(path)
                    if isDirectory(folder) { folders.append(folder.standardizedFileURL) }
                }
            }
        }
        return folders.map { SearchPath(directory: $0, allowed: allowed) }
    }

    /// The top-level packages of an `entry_points.txt`'s `[pyshader.modules]`
    /// section: `noise = noise` (or `= shaderlib.noise`) declares `noise`
    /// (`shaderlib`) a PyShader module.
    static func declaredModules(entryPoints text: String) -> Swift.Set<String> {
        var modules: Swift.Set<String> = []
        var inSection = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line == "[pyshader.modules]"
                continue
            }
            guard inSection, let eq = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let module = value.split(separator: ":").first.map(String.init) ?? value
            if let top = module.split(separator: ".").first, !top.isEmpty {
                modules.insert(String(top))
            }
        }
        return modules
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Lookup

    /// A module's source, found.
    struct Located {
        let source: String
        /// For errors and `OpString`: relative to the folder it was found in.
        let file: String
        let isPackage: Bool
    }

    enum Lookup {
        case found(Located)
        /// On a site-packages path, but no distribution declares it a PyShader module.
        case notShaderModule(file: String)
        case missing
    }

    func locate(_ name: String) -> Lookup {
        let parts = name.split(separator: ".").map(String.init)
        if let source = sources[name] {
            let isPackage = sources.keys.contains { $0.hasPrefix(name + ".") }
            let file = parts.joined(separator: "/") + (isPackage ? "/__init__.py" : ".py")
            return .found(Located(source: source, file: file, isPackage: isPackage))
        }
        if sources.keys.contains(where: { $0.hasPrefix(name + ".") }) {
            // A package with no source of its own (a namespace package).
            return .found(Located(source: "", file: parts.joined(separator: "/") + "/", isPackage: true))
        }
        var undeclared: String?
        for path in paths {
            let relative = parts.joined(separator: "/")
            let candidates: [(String, Bool)] = [(relative + ".py", false), (relative + "/__init__.py", true)]
            var hit: (file: String, source: String, isPackage: Bool)?
            for (file, isPackage) in candidates {
                let url = path.directory.appendingPathComponent(file)
                if let source = try? String(contentsOf: url, encoding: .utf8) {
                    hit = (file, source, isPackage)
                    break
                }
            }
            if hit == nil, Self.isDirectory(path.directory.appendingPathComponent(relative)) {
                hit = (relative + "/", "", true)
            }
            guard let hit else { continue }
            if let allowed = path.allowed, !allowed.contains(parts[0]) {
                undeclared = undeclared ?? hit.file
                continue
            }
            return .found(Located(source: hit.source, file: hit.file, isPackage: hit.isPackage))
        }
        if let undeclared { return .notShaderModule(file: undeclared) }
        return .missing
    }
}
