//
//  ShaderModules.swift
//  PyShader
//
//  Where `import` finds PyShader modules: the shader's own folder and a
//  site-packages folder, where only the packages that declare a
//  `pyshader.modules` entry point count. Tests hand sources over in memory.
//

import Foundation

/// The places a shader's imports are looked up, in order.
struct ShaderModules: Sendable {
    /// One folder modules are looked up in, like an entry of Python's `sys.path`.
    struct SearchPath: Sendable, Equatable {
        let directory: URL
        /// The modules importable from here, dotted, with everything below
        /// them; nil for any. A site-packages folder holds every Python
        /// package of the environment, so only the ones a distribution
        /// declares under the `pyshader.modules` entry point are let through.
        let allowed: Swift.Set<String>?

        /// `name` is a declared module, inside one, or a package on the way to one.
        func allows(_ name: String) -> Bool {
            guard let allowed else { return true }
            return allowed.contains { name == $0 || name.hasPrefix($0 + ".") || $0.hasPrefix(name + ".") }
        }

        init(directory: URL, allowed: Swift.Set<String>? = nil) {
            self.directory = directory
            self.allowed = allowed
        }
    }

    /// Module sources by dotted name (`"noise"`, `"shaderlib.noise"`); a
    /// package's own source is its `__init__.py`. Looked up before `paths`.
    var sources: [String: String]
    var paths: [SearchPath]

    init(sources: [String: String] = [:], paths: [SearchPath] = []) {
        self.sources = sources
        self.paths = paths
    }

    /// Nothing to import from: any import besides `pyshader` is an error.
    static let none = ShaderModules()

    /// The PyShader modules installed in a site-packages folder.
    init(sitePackages: URL) {
        self.init(paths: Self.searchPaths(forSitePackages: sitePackages.standardizedFileURL))
    }

    /// What a shader file on disk imports from: its own folder, then
    /// `sitePackages` — by default the site-packages of the nearest `.venv`
    /// above the file (or of `VIRTUAL_ENV` when there is none), where
    /// `uv add` installs a shader library.
    static func discover(near file: URL, sitePackages: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> ShaderModules {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        var paths = [SearchPath(directory: folder)]
        if let sitePackages {
            paths += searchPaths(forSitePackages: sitePackages.standardizedFileURL)
        } else if let venv = nearestVenv(from: folder) ?? environment["VIRTUAL_ENV"].map({ URL(fileURLWithPath: $0) }) {
            for site in Self.sitePackages(in: venv) { paths += searchPaths(forSitePackages: site) }
        }
        return ShaderModules(paths: paths)
    }

    /// The first `.venv` folder in `folder` or above it.
    static func nearestVenv(from folder: URL) -> URL? {
        var dir = folder.standardizedFileURL
        while true {
            let venv = dir.appendingPathComponent(".venv")
            if isDirectory(venv) { return venv }
            // Stop at the root by its path: the parent of a folder URL
            // `file:///` is `file:///../`, so comparing parent and child
            // never ends.
            if dir.path == "/" { return nil }
            dir = dir.deletingLastPathComponent()
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
    static func searchPaths(forSitePackages site: URL) -> [SearchPath] {
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

    /// The modules of an `entry_points.txt`'s `[pyshader.modules]` section:
    /// `noise = noise` declares `noise` a PyShader module, `stdlib =
    /// pyshader.stdlib` declares `pyshader.stdlib` (and nothing else of `pyshader`).
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
            if !module.isEmpty { modules.insert(module) }
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
            if !path.allows(name) {
                undeclared = undeclared ?? hit.file
                continue
            }
            return .found(Located(source: hit.source, file: hit.file, isPackage: hit.isPackage))
        }
        if let undeclared { return .notShaderModule(file: undeclared) }
        return .missing
    }
}
