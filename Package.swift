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
    ],
    dependencies: [
        .package(url: "https://github.com/Py-Swift/PySwiftAST.git", branch: "master"),
        .package(url: "https://github.com/NucleantUI/SpirvCore.git", branch: "master"),
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
