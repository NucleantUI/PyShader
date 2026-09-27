// swift-tools-version: 6.2
//
// Liquid glass as a NucleantUI effect: `liquid-glass.py` (the PyShader
// port of lq.glsl next to it) on rounded rects, labels and buttons, each a
// `.shader(_:backdrop: true)` pad over a busy backdrop.
//
// The .py is read from the parent folder at launch, so editing it and
// relaunching is the whole loop.
//
//   cd Examples/liquid_glass/App && swift run
//

import PackageDescription

let package = Package(
    name: "LiquidGlassExample",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    dependencies: [
        .package(path: "../../../../NucleantUI"),
        .package(path: "../../.."),
    ],
    targets: [
        .executableTarget(
            name: "LiquidGlassExample",
            dependencies: [
                .product(name: "NucleantUI", package: "NucleantUI"),
                .product(name: "PyShader", package: "PyShader"),
            ]
        ),
    ]
)
