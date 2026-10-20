# Package plugins

Two SwiftPM plugins compile a package's shaders to SPIR-V ahead of time, so
nothing has to compile them at runtime. Both read `pyshader.toml` at the
root of the package and run [`pyshaderc`](api.md#pyshaderc) once per section.

| plugin | when | writes |
|---|---|---|
| `PyShaderBuildPlugin` | every build of the target it is applied to, again whenever a source, a module it may import or the config changes | each section's `.spv` into the build, where it is one of the target's resources (`Bundle.module`) |
| `PyShaderCommandPlugin` | `swift package pyshader-compile [section]...` | each section's `.spv` to its `output` path in the package |

## `pyshader.toml`

```toml title="pyshader.toml"
# Where imported shader libraries are installed, for every section (optional;
# by default the site-packages of the nearest .venv above each source).
site-packages = ".venv/lib/python3.13/site-packages"

[clouds]
source = "Shaders/clouds.py"
output = "Resources/clouds.spv"      # default: <section>.spv
target = "compute"                   # fragment (default) | compute | graphics
content-top-down = true              # pyshaderc --content-top-down (or content = true: --content)
arguments = ["gain:float", "tint:float4"]   # pyshaderc --arg, in order
optimize = ["-O"]                    # pyshaderc --optimize: spirv-opt passes, in order
```

Each `[section]` is one shader. Paths are relative to the file. The keys
are `pyshaderc`'s options: `target`, `content`, `content-top-down`,
`arguments` and `optimize` mean what `--target`, `--content`,
`--content-top-down`, `--arg` and `--optimize` do; `site-packages` is
`--site-packages`, and like it, only the packages that declare a
`pyshader.modules` entry point can be imported from it (see
[Modules](../language/modules.md)). A module beside the source is always
importable. The build plugin uses only the file name of `output`.
`content-top-down` is the one for NucleantUI's `.shader(_:)`: it hands a
module the view top-down, as it is stored, and `layer(uv)` then reads it
upright; with `content` alone it reads that view upside down.

Only the TOML this needs is read: tables, `#` comments, and keys holding
strings, `true` / `false` or arrays of strings.

## Build plugin

```swift title="Package.swift"
dependencies: [
    .package(url: "https://github.com/NucleantUI/PyShader.git", .upToNextMinor(from: "0.0.5")),
],
targets: [
    .executableTarget(
        name: "App",
        exclude: ["Shaders"],   // the .py files are the plugin's input, not resources
        plugins: [.plugin(name: "PyShaderBuildPlugin", package: "PyShader")]
    ),
]
```

```swift
let url = Bundle.module.url(forResource: "clouds", withExtension: "spv")!
let words = try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
```

A shader that does not compile fails the build with
`path/to/shader.py:12: error: …`, which Xcode and editors link to the line.
`pyshaderc` is built for the host from source, as part of the same build.

## Command plugin

```sh
swift package --allow-writing-to-package-directory pyshader-compile          # every section
swift package --allow-writing-to-package-directory pyshader-compile clouds   # just these
```

For `.spv` files that are committed, or shipped by something other than
SwiftPM. Without `--allow-writing-to-package-directory`, SwiftPM asks first.

[Examples/precompiled](https://github.com/NucleantUI/PyShader/tree/main/Examples/precompiled)
is a package that uses both: a shader that imports a module beside it, and
two of the repository's other examples, one of them a vertex + fragment pair.
