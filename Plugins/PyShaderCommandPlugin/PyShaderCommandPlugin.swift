//
//  PyShaderCommandPlugin.swift
//  PyShaderCommandPlugin
//
//  `swift package pyshader-compile [section]...`: compiles the sections of
//  the package's `pyshader.toml` (all of them, or the ones named) to SPIR-V
//  with `pyshaderc`, writing each to its `output` path in the package.
//

import Foundation
import PackagePlugin

@main
struct PyShaderCommandPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let root = context.package.directoryURL
        let configFile = root.appendingPathComponent(PyShaderConfig.fileName)
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            Diagnostics.error("PyShader: no \(PyShaderConfig.fileName) at the root of package `\(context.package.displayName)`")
            return
        }
        let config = try PyShaderConfig(contentsOf: configFile)
        let names = Set(config.sections.map(\.name))
        if let unknown = arguments.first(where: { !names.contains($0) }) {
            Diagnostics.error("PyShader: no section `\(unknown)` in \(PyShaderConfig.fileName); there are: \(config.sections.map(\.name).joined(separator: ", "))")
            return
        }
        let compiler = try context.tool(named: "pyshaderc").url
        var failed = 0
        for section in config.sections where arguments.isEmpty || arguments.contains(section.name) {
            let output = root.appendingPathComponent(section.output)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = compiler
            process.arguments = config.compilerArguments(for: section, root: root, output: output)
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                Diagnostics.error("PyShader: section `\(section.name)` failed")
                failed += 1
            }
        }
        if failed > 0 { throw CommandError(count: failed) }
    }

    struct CommandError: Error, CustomStringConvertible {
        let count: Int
        var description: String { "\(count) section(s) failed to compile" }
    }
}
