//
//  Catalog.swift
//
//  The shaders are `.py` files in Resources/Shaders and Resources/Effects,
//  copied into the bundle and read as strings here. Each file starts with a
//  docstring whose first line is the name and whose remaining text is the
//  blurb; the numeric prefix on the file name fixes the order.
//

import Foundation
import NucleantSwiftUI

struct CatalogEntry: Identifiable {
    let id: Int
    let name: String
    let blurb: String
    let file: String
    let function: ShaderFunction
    /// Arguments the shader takes by name, if any (see `08_tint.py`).
    let arguments: [ShaderArgument]
}

enum Catalog {
    static let shaders = load(subdirectory: "Shaders")
    static let effects = load(subdirectory: "Effects")

    /// Arguments per file, for shaders that declare `ShaderArgument` parameters.
    private static let arguments: [String: [ShaderArgument]] = [
        "08_tint.py": [.color("tint", .orange), .float("strength", 0.45)],
    ]

    private static func load(subdirectory: String) -> [CatalogEntry] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "py", subdirectory: subdirectory) ?? []
        return urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .enumerated()
            .compactMap { index, url in
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let (name, blurb) = docstring(of: source, fallback: url.deletingPathExtension().lastPathComponent)
                return CatalogEntry(
                    id: index,
                    name: name,
                    blurb: blurb,
                    file: url.lastPathComponent,
                    function: ShaderFunction(pyshader: source),
                    arguments: arguments[url.lastPathComponent] ?? []
                )
            }
    }

    /// `"""Name\n\nBlurb..."""` at the top of the file.
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
