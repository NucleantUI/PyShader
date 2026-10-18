// swift-tools-version: 6.1

// Shaders compiled to SPIR-V before the app runs: the build plugin compiles
// every section of pyshader.toml on each build, and the `.spv` files ship as
// the target's resources; `swift package pyshader-compile` writes the same
// files into the package on demand. The app loads words, not Python.

import PackageDescription

let package = Package(
    name: "PrecompiledShaders",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "ShaderPack",
            exclude: ["Shaders"],
            plugins: [.plugin(name: "PyShaderBuildPlugin", package: "PyShader")]
        ),
    ]
)
