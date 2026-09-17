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
            name: "SpirvCore",
            targets: ["SpirvCore"]
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
    ],
    dependencies: [
        .package(url: "https://github.com/Py-Swift/PySwiftAST.git", branch: "master"),
    ],
    targets: [
        // The SPIR-V opcode tables, instruction encoding and a word-stream
        // reader, shared by the compiler and the decompiler.
        .target(
            name: "SpirvCore"
        ),
        .target(
            name: "PyShader",
            dependencies: [
                "SpirvCore",
                .product(name: "PySwiftAST", package: "PySwiftAST"),
            ]
        ),
        // SPIR-V (a fragment stage) back to PyShader source.
        .target(
            name: "Spirv2PyShader",
            dependencies: ["SpirvCore", "PyShader"]
        ),
        .executableTarget(
            name: "pyshaderc",
            dependencies: ["PyShader"]
        ),
        .executableTarget(
            name: "spirv2py",
            dependencies: ["Spirv2PyShader"]
        ),
        .testTarget(
            name: "PyShaderTests",
            dependencies: ["PyShader"]
        ),
        .testTarget(
            name: "Spirv2PyShaderTests",
            dependencies: ["Spirv2PyShader", "PyShader"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
