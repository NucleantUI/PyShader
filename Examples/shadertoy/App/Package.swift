// swift-tools-version: 6.2
//
// Side-by-side check of the ShaderToy ports: every shader in
// Examples/shadertoy/opengl has a PyShader version in Examples/shadertoy/pyshader,
// and this app runs both — the GLSL through `ShaderFunction(shaderToy:)`, the
// Python through `ShaderFunction(pyshader:)` — next to each other.
//
// The sources are read from the sibling folders at launch (not bundled), so
// editing a .py and relaunching is the whole loop.
//
//   cd Examples/shadertoy/App && swift run
//   PYSHADER_EXAMPLE_START=cube-lines swift run    # open one comparison directly
//

import PackageDescription

let package = Package(
    name: "ShadertoyExample",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    dependencies: [
        .package(path: "../../../../NucleantSwiftUI"),
        .package(path: "../../.."),
    ],
    targets: [
        .executableTarget(
            name: "ShadertoyExample",
            dependencies: [
                .product(name: "NucleantSwiftUI", package: "NucleantSwiftUI"),
                .product(name: "PyShader", package: "PyShader"),
            ]
        ),
    ]
)
