//
//  PyShaderSwiftUIExample
//
//  PyShader inside NucleantSwiftUI, in the shape of NucleantSwiftUI's demo:
//  a "Shaders" gallery of `Shader` views and an "Effects" gallery of
//  `.shader(_:)` effects over a card, every row a live thumbnail and every
//  entry opening full screen. The sources are the `.py` files in Resources/.
//
//  A shader that fails to compile is reported on stderr by NucleantSwiftUI
//  ("shader node build ... failed: PyShader: line N: ...") and its rect
//  stays empty.
//

import Foundation
import NucleantSwiftUI
import PyShader

enum Palette {
    static let background = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let panel = Color(red: 0.13, green: 0.15, blue: 0.19)
    static let panelHighlight = Color(red: 0.17, green: 0.19, blue: 0.24)
    static let accent = Color(red: 0.35, green: 0.55, blue: 1.0)
    static let good = Color(red: 0.35, green: 0.8, blue: 0.5)
    static let warn = Color(red: 0.95, green: 0.7, blue: 0.3)
    static let muted = Color(red: 0.35, green: 0.37, blue: 0.42)
}

// MARK: - Shaders

/// One shader, full screen.
@View
struct ShaderScreen {
    let entry: CatalogEntry

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(entry.blurb)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Text(entry.file)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Shader(entry.function, arguments: entry.arguments)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .cornerRadius(12)
        }
        .padding(16)
    }
}

/// The gallery: every row carries a live thumbnail, so this screen runs one
/// compute node per shader at once.
@View
struct ShaderGalleryScreen {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(Catalog.shaders.count) PyShader shaders from Resources/Shaders, each its own GPU node.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                ForEach(Catalog.shaders) { entry in
                    NavigationLink(title: entry.name) {
                        ShaderScreen(entry: entry)
                    } label: {
                        GalleryRow(entry: entry) {
                            Shader(entry.function, arguments: entry.arguments)
                                .frame(width: 120, height: 68)
                                .cornerRadius(6)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Effects

/// The view every effect row is applied to.
@View
struct EffectPreviewCard {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PyShader")
                .font(.system(size: 16, weight: .semibold))
            HStack(spacing: 8) {
                Circle().fill(Palette.accent).frame(width: 12, height: 12)
                Capsule().fill(Palette.good).frame(width: 64, height: 8)
                Capsule().fill(Palette.warn).frame(width: 32, height: 8)
            }
            Text("the view as a texture")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(width: 200, height: 92, alignment: .leading)
        .background(Palette.panel)
        .cornerRadius(10)
    }
}

/// A bigger card under one effect, with the effect toggleable so the
/// difference is visible.
@View
struct EffectScreen {
    let entry: CatalogEntry
    @State private var isEnabled = true

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(entry.blurb)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Button(isEnabled ? "Effect on" : "Effect off") { isEnabled.toggle() }
                    .tint(isEnabled ? Palette.accent : Palette.muted)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text(entry.name)
                    .font(.title)
                Text(entry.file)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Circle().fill(Palette.accent).frame(width: 28, height: 28)
                    Capsule().fill(Palette.good).frame(width: 160, height: 14)
                    Capsule().fill(Palette.warn).frame(width: 90, height: 14)
                }
                Text("Everything on this card is drawn into a texture and read back through layer(uv) by the Python shader.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.panel)
            .cornerRadius(14)
            .shader(entry.function, arguments: entry.arguments, isEnabled: isEnabled)
        }
        .padding(16)
    }
}

@View
struct EffectsScreen {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(Catalog.effects.count) PyShader effects from Resources/Effects over the same card — each row its own canvas, sampled with layer(uv).")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                ForEach(Catalog.effects) { entry in
                    NavigationLink(title: entry.name) {
                        EffectScreen(entry: entry)
                    } label: {
                        GalleryRow(entry: entry) {
                            EffectPreviewCard()
                                .shader(entry.function, arguments: entry.arguments)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Shared

/// A gallery row: thumbnail, name, blurb, chevron.
@View
struct GalleryRow<Thumbnail: View> {
    let entry: CatalogEntry
    @ViewBuilder let thumbnail: () -> Thumbnail

    var body: some View {
        HStack(spacing: 14) {
            thumbnail()

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

@View
struct RootScreen {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PyShader × NucleantSwiftUI")
                .font(.title)
            Text("Shaders written in Python syntax, compiled straight to SPIR-V at runtime. Each entry is a .py file in Resources/ starting with `from pyshader import *`.")
                .font(.footnote)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                NavigationLink("Shaders") { ShaderGalleryScreen() }
                NavigationLink("Effects") { EffectsScreen() }
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// `PYSHADER_EXAMPLE_START=shaders|effects` opens a gallery directly — for
/// screenshots and scripted checks; the root screen otherwise.
@View
struct StartScreen {
    var body: some View {
        switch ProcessInfo.processInfo.environment["PYSHADER_EXAMPLE_START"] {
        case "shaders": ShaderGalleryScreen()
        case "effects": EffectsScreen()
        default: RootScreen()
        }
    }
}

struct ExampleApp: NucleantApp {
    var body: some Scene {
        WindowGroup("PyShader × NucleantSwiftUI", width: 900, height: 620) {
            NavigationStack("PyShader") {
                StartScreen()
            }
            .background(Palette.background)
        }
    }
}

ExampleApp.main()
