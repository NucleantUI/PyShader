// swift-tools-version: 6.2
//
// A stand-alone app showing PyShader shaders inside NucleantUI, laid out
// like NucleantUI's own demo: a gallery of `Shader` views and a gallery
// of `.shader(_:)` effects, each opening full screen. Every shader is a `.py`
// file under Resources/, loaded as a string and compiled to SPIR-V by PyShader
// at runtime. Lives here, not in NucleantUI's demo, so the demo stays
// what it is.
//
// Build & run from this directory:  swift run PyShaderSwiftUIExample
//

import PackageDescription

let package = Package(
    name: "PyShaderSwiftUIExample",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    dependencies: [
        .package(path: "../../../NucleantUI"),
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "PyShaderSwiftUIExample",
            dependencies: [
                .product(name: "NucleantUI", package: "NucleantUI"),
                .product(name: "PyShader", package: "PyShader"),
            ],
            resources: [
                .copy("Resources/Shaders"),
                .copy("Resources/Effects"),
            ]
        ),
    ]
)
