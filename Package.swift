// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "PyShader",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "PyShader",
            targets: ["PyShader"]
        ),
        .library(
            name: "Spirv2PyShader",
            targets: ["Spirv2PyShader"]
        ),
        .executable(
            name: "pyshaderc",
            targets: ["pyshaderc"]
        ),
        .executable(
            name: "spirv2py",
            targets: ["spirv2py"]
        ),
        // Compile the shaders a package's pyshader.toml lists: on every build...
        .plugin(
            name: "PyShaderBuildPlugin",
            targets: ["PyShaderBuildPlugin"]
        ),
        // ...or on demand, `swift package pyshader-compile`.
        .plugin(
            name: "PyShaderCommandPlugin",
            targets: ["PyShaderCommandPlugin"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Py-Swift/PySwiftAST.git", .upToNextMinor(from: "0.0.1")),
        .package(url: "https://github.com/NucleantUI/SpirvCore.git", .upToNextMinor(from: "0.0.1")),
    ],
    targets: [
        .target(
            name: "PyShader",
            dependencies: [
                .product(name: "SpirvCore", package: "SpirvCore"),
                .product(name: "PySwiftAST", package: "PySwiftAST"),
            ]
        ),
        // SPIR-V (a fragment stage) back to PyShader source.
        .target(
            name: "Spirv2PyShader",
            dependencies: [
                .product(name: "SpirvCore", package: "SpirvCore"),
                "PyShader",
            ]
        ),
        .executableTarget(
            name: "pyshaderc",
            dependencies: ["PyShader"]
        ),
        .executableTarget(
            name: "spirv2py",
            dependencies: ["Spirv2PyShader"]
        ),
        // pyshader.toml; its one file is also linked into both plugins.
        .target(name: "PyShaderConfig"),
        .plugin(
            name: "PyShaderBuildPlugin",
            capability: .buildTool(),
            dependencies: ["pyshaderc"]
        ),
        .plugin(
            name: "PyShaderCommandPlugin",
            capability: .command(
                intent: .custom(verb: "pyshader-compile", description: "Compile the shaders in pyshader.toml to SPIR-V"),
                permissions: [.writeToPackageDirectory(reason: "Writes each section's SPIR-V to its `output` path")]
            ),
            dependencies: ["pyshaderc"]
        ),
        .testTarget(
            name: "PyShaderTests",
            dependencies: ["PyShader", "PyShaderConfig"]
        ),
        .testTarget(
            name: "Spirv2PyShaderTests",
            dependencies: ["Spirv2PyShader", "PyShader"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
