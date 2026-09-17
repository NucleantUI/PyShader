// swift-tools-version: 6.2
//
// A stand-alone app showing PyShader shaders inside NucleantSwiftUI, laid out
// like NucleantSwiftUI's own demo: a gallery of `Shader` views and a gallery
// of `.shader(_:)` effects, each opening full screen. Every shader is a `.py`
// file under Resources/, loaded as a string and compiled to SPIR-V by PyShader
// at runtime. Lives here, not in NucleantSwiftUI's demo, so the demo stays
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
        .package(path: "../../../NucleantSwiftUI"),
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "PyShaderSwiftUIExample",
            dependencies: [
                .product(name: "NucleantSwiftUI", package: "NucleantSwiftUI"),
                .product(name: "PyShader", package: "PyShader"),
            ],
            resources: [
                .copy("Resources/Shaders"),
                .copy("Resources/Effects"),
            ]
        ),
    ]
)
