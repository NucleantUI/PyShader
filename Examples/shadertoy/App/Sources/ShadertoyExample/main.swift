//
//  ShadertoyExample
//
//  Gallery of the ShaderToy ports with the GLSL original and the PyShader
//  version running side by side. A port is right when the two halves match.
//

import Foundation
import NucleantSwiftUI
import PyShader

enum Palette {
    static let background = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let panel = Color(red: 0.13, green: 0.15, blue: 0.19)
    static let panelHighlight = Color(red: 0.17, green: 0.19, blue: 0.24)
    static let accent = Color(red: 0.35, green: 0.55, blue: 1.0)
    static let muted = Color(red: 0.35, green: 0.37, blue: 0.42)
}

struct Comparison: Identifiable {
    let id: Int
    /// File name without extension, the same in opengl/ and pyshader/.
    let file: String
    let name: String
    let blurb: String
    let glsl: ShaderFunction
    let pyshader: ShaderFunction
}

enum Catalog {
    /// Examples/shadertoy, found from this file rather than a bundle so the
    /// .py files can be edited and re-run without a rebuild.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ShadertoyExample
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // App
        .deletingLastPathComponent()   // shadertoy
    static let openglDirectory = root.appendingPathComponent("opengl")
    static let pyshaderDirectory = root.appendingPathComponent("pyshader")

    /// Lines put in front of a GLSL source so it compiles under NucleantSwiftUI's
    /// compute wrapper: `fwidth` does not exist in a compute shader, and a zero
    /// width sends cube-lines down the same 8-tap `fcos` path the port uses.
    static let glslPrelude: [String: String] = [
        "cube-lines": "#define fwidth(x) (vec3(0.0))\n",
    ]

    static let comparisons: [Comparison] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: pyshaderDirectory.path)) ?? []
        return files
            .filter { $0.hasSuffix(".py") }
            .sorted()
            .enumerated()
            .compactMap { index, file in
                let name = String(file.dropLast(3))
                guard let python = try? String(contentsOf: pyshaderDirectory.appendingPathComponent(file), encoding: .utf8),
                      let glsl = try? String(contentsOf: openglDirectory.appendingPathComponent(name + ".glsl"), encoding: .utf8)
                else { return nil }
                let (title, blurb) = docstring(of: python, fallback: name)
                return Comparison(
                    id: index,
                    file: name,
                    name: title,
                    blurb: blurb,
                    // ShaderToy ignores the alpha a shader writes; NucleantSwiftUI composites with
                    // it, so force it opaque after mainImage — which is all `shaderToy:` adds anyway.
                    glsl: ShaderFunction(
                        functions: (glslPrelude[name] ?? "") + glsl,
                        "mainImage(fragColor, fragCoord); fragColor.a = 1.0;"
                    ),
                    pyshader: ShaderFunction(pyshader: python)
                )
            }
    }()

    private static func docstring(of source: String, fallback: String) -> (String, String) {
        guard let open = source.range(of: "\"\"\""),
              let close = source.range(of: "\"\"\"", range: open.upperBound..<source.endIndex) else {
            return (fallback, "")
        }
        let text = source[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let name = lines.first.map(String.init) ?? fallback
        let blurb = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (name, blurb)
    }
}

/// GLSL on the left, PyShader on the right, same size, same clock.
@View
struct ComparisonScreen {
    let entry: Comparison

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(entry.blurb)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Text("opengl/\(entry.file).glsl  ·  pyshader/\(entry.file).py")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                VStack(spacing: 6) {
                    Text("GLSL (opengl/)")
                        .font(.headline)
                    Shader(entry.glsl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .cornerRadius(10)
                }
                VStack(spacing: 6) {
                    Text("PyShader (pyshader/)")
                        .font(.headline)
                    Shader(entry.pyshader)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .cornerRadius(10)
                }
            }
        }
        .padding(16)
    }
}

@View
struct GalleryScreen {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(Catalog.comparisons.count) ShaderToy shaders — thumbnails are the PyShader ports; open one to see it beside the GLSL original.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                if Catalog.comparisons.isEmpty {
                    Text("No shader pairs found under \(Catalog.root.path) — expected opengl/NAME.glsl and pyshader/NAME.py.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                ForEach(Catalog.comparisons) { entry in
                    NavigationLink(title: entry.name) {
                        ComparisonScreen(entry: entry)
                    } label: {
                        HStack(spacing: 14) {
                            Shader(entry.pyshader)
                                .frame(width: 120, height: 68)
                                .cornerRadius(6)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name)
                                    .font(.system(size: 16, weight: .medium))
                                Text(entry.blurb)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Text("›")
                                .font(.system(size: 20))
                                .foregroundColor(.secondary)
                        }
                        .padding(horizontal: 14, vertical: 10)
                        .background(Palette.panelHighlight)
                        .cornerRadius(12)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// `PYSHADER_EXAMPLE_START=<file name without .py>` opens that comparison directly.
@View
struct StartScreen {
    var body: some View {
        let start = ProcessInfo.processInfo.environment["PYSHADER_EXAMPLE_START"]
        if let start, let entry = Catalog.comparisons.first(where: { $0.file == start }) {
            ComparisonScreen(entry: entry)
        } else {
            GalleryScreen()
        }
    }
}

struct ShadertoyApp: NucleantApp {
    var body: some Scene {
        WindowGroup("PyShader × ShaderToy", width: 1100, height: 640) {
            NavigationStack("ShaderToy ports") {
                StartScreen()
            }
            .background(Palette.background)
        }
    }
}

ShadertoyApp.main()
