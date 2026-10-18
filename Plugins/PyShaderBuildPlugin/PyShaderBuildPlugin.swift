//
//  PyShaderBuildPlugin.swift
//  PyShaderBuildPlugin
//
//  Build tool plugin: compiles every section of the package's
//  `pyshader.toml` to SPIR-V as part of the build, with `pyshaderc`. Each
//  `.spv` lands in the plugin's work folder under the file name of the
//  section's `output`, and is rebuilt when the source, a module it may
//  import, or the config changes.
//

import Foundation
import PackagePlugin

@main
struct PyShaderBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let root = context.package.directoryURL
        let configFile = root.appendingPathComponent(PyShaderConfig.fileName)
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            Diagnostics.warning("PyShader: no \(PyShaderConfig.fileName) at the root of package `\(context.package.displayName)`; nothing to compile")
            return []
        }
        let config = try PyShaderConfig(contentsOf: configFile)
        let compiler = try context.tool(named: "pyshaderc").url
        return config.sections.map { section in
            let output = context.pluginWorkDirectoryURL.appendingPathComponent((section.output as NSString).lastPathComponent)
            return .buildCommand(
                displayName: "PyShader \(section.name): \(section.source)",
                executable: compiler,
                arguments: config.compilerArguments(for: section, root: root, output: output),
                inputFiles: config.inputFiles(for: section, root: root, configFile: configFile),
                outputFiles: [output]
            )
        }
    }
}
