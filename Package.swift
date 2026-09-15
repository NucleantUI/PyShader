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
        .executable(
            name: "pyshaderc",
            targets: ["pyshaderc"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Py-Swift/PySwiftAST.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "PyShader",
            dependencies: [
                .product(name: "PySwiftAST", package: "PySwiftAST"),
            ]
        ),
        .executableTarget(
            name: "pyshaderc",
            dependencies: ["PyShader"]
        ),
        .testTarget(
            name: "PyShaderTests",
            dependencies: ["PyShader"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
