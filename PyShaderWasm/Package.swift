// swift-tools-version: 6.1

import PackageDescription

// Built with the wasm Swift SDK (see scripts/build_wasm.py) into a WASI reactor
// module the docs' WebGPU preview loads in the browser.
let package = Package(
    name: "PyShaderWasm",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "PyShaderWasm",
            targets: ["PyShaderWasm"]
        ),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "PyShaderWasm",
            dependencies: [
                .product(name: "PyShader", package: "PyShader"),
                .product(name: "Spirv2PyShader", package: "PyShader"),
                "ICUDataStub",
            ]
        ),
        .target(name: "ICUDataStub"),
    ],
    swiftLanguageModes: [.v6]
)
