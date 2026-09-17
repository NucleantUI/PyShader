//
//  LiquidGlassExample
//
//  A home screen whose app icons are liquid glass: each icon is a
//  translucent colour slab with liquid-glass.py over it, `backdrop: true`,
//  so the wallpaper refracts through the colour and the glyph bends at the
//  rim. The toolbar is glass too; `Thicker` / `Thinner` change the icons'
//  bevel. No dock: effects do not nest, and a bar that is not glass has no
//  place here.
//

import Foundation
import NucleantSwiftUI
import PyShader

enum Glass {
    /// Examples/liquid_glass, found from this file rather than a bundle.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // main.swift
        .deletingLastPathComponent()   // LiquidGlassExample
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // App

    static let function: ShaderFunction = {
        let url = root.appendingPathComponent("liquid-glass.py")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("liquid-glass.py not found at \(url.path)")
        }
        return ShaderFunction(pyshader: source)
    }()
}

/// `content` under liquid glass. The texture is the backdrop plus the
/// content, so a label or an icon inside stays as drawn — the pad is flat
/// away from its rim — and is not covered by the composite (a shader's
/// output lands *over* the canvas, so anything drawn above the pad would
/// vanish).
///
/// `margin` is transparent padding around the content that the pad is
/// inset from: the rim bends what is up to ~9 × thickness inward, and a
/// layer is only the view's rect, so a small view needs the extra texture
/// or the rim shows the edge texel instead of the wallpaper past it.
/// `cornerRadius`, `thickness` and `margin` are points; the shader wants
/// pixels.
@View
struct Glassed<Content: View> {
    let content: Content
    var cornerRadius: Double = 16
    var thickness: Double = 5
    var margin: Double = 0
    var isEnabled: Bool = true

    @Environment(\.displayScale) private var scale

    var body: some View {
        content
            .padding(margin)
            .shader(
                Glass.function,
                arguments: [
                    .float("radius", cornerRadius * scale),
                    .float("thickness", thickness * scale),
                    .float("inset", margin * scale),
                ],
                backdrop: true,
                isEnabled: isEnabled
            )
    }
}

extension View {
    func liquidGlass(cornerRadius: Double = 16, thickness: Double = 5, margin: Double = 0, isEnabled: Bool = true) -> some View {
        Glassed(content: self, cornerRadius: cornerRadius, thickness: thickness, margin: margin, isEnabled: isEnabled)
    }
}

// MARK: - Icons

struct AppIcon: Identifiable {
    let id: String
    let top: Color
    let bottom: Color
    let glyph: Glyph

    enum Glyph {
        case phone, messages, music, camera, mail, clock, photos, weather, settings, maps, notes, safari
    }
}

let apps: [AppIcon] = [
    AppIcon(id: "Phone", top: Color(hex: 0x5AF06F), bottom: Color(hex: 0x1EB841), glyph: .phone),
    AppIcon(id: "Messages", top: Color(hex: 0x5CF477), bottom: Color(hex: 0x20B43E), glyph: .messages),
    AppIcon(id: "Music", top: Color(hex: 0xFF6A7A), bottom: Color(hex: 0xF0263D), glyph: .music),
    AppIcon(id: "Camera", top: Color(hex: 0x8E8E93), bottom: Color(hex: 0x3A3A3C), glyph: .camera),
    AppIcon(id: "Mail", top: Color(hex: 0x4AB8FF), bottom: Color(hex: 0x1470E0), glyph: .mail),
    AppIcon(id: "Clock", top: Color(hex: 0x2C2C2E), bottom: Color(hex: 0x1C1C1E), glyph: .clock),
    AppIcon(id: "Photos", top: Color(hex: 0xFFFFFF), bottom: Color(hex: 0xF2F2F7), glyph: .photos),
    AppIcon(id: "Weather", top: Color(hex: 0x4FA8FF), bottom: Color(hex: 0x1E5FD6), glyph: .weather),
    AppIcon(id: "Settings", top: Color(hex: 0x9A9AA0), bottom: Color(hex: 0x5C5C61), glyph: .settings),
    AppIcon(id: "Maps", top: Color(hex: 0xC8F0A0), bottom: Color(hex: 0x5AC85A), glyph: .maps),
    AppIcon(id: "Notes", top: Color(hex: 0xFFE27A), bottom: Color(hex: 0xFFD130), glyph: .notes),
    AppIcon(id: "Safari", top: Color(hex: 0x4FC3FF), bottom: Color(hex: 0x1B7BEA), glyph: .safari),
]

/// A glass icon: a translucent colour slab with a glyph drawn from shapes,
/// under liquid glass. The wallpaper shows through the colour; the rim
/// bends colour, glyph and wallpaper alike. `thickness` of the bevel in
/// points — the ShaderToy original is 14 px on a 128 px pad, so about an
/// eighth of the icon.
@View
struct IconView {
    let app: AppIcon
    var size: Double = 64
    var thickness: Double = 8
    var isGlass: Bool = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(.linearGradient(
                    colors: [app.top.opacity(0.75), app.bottom.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            glyph
        }
        .frame(width: size, height: size)
        .liquidGlass(cornerRadius: size * 0.23, thickness: thickness, margin: size * 0.375, isEnabled: isGlass)
    }

    @ViewBuilder
    private var glyph: some View {
        let s = size
        switch app.glyph {
        case .phone:
            Capsule().fill(Color.white)
                .frame(width: s * 0.16, height: s * 0.5)
                .rotationEffect(.init(degrees: -45))
        case .messages:
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: s * 0.22).fill(Color.white)
                    .frame(width: s * 0.58, height: s * 0.44)
                Circle().fill(Color.white).frame(width: s * 0.16, height: s * 0.16)
                    .padding(EdgeInsets(leading: -s * 0.02, bottom: -s * 0.05))
            }
        case .music:
            HStack(alignment: .bottom, spacing: s * 0.02) {
                Circle().fill(Color.white).frame(width: s * 0.2, height: s * 0.2)
                Rectangle().fill(Color.white).frame(width: s * 0.06, height: s * 0.45)
                    .padding(.bottom, s * 0.08)
            }
        case .camera:
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.1).fill(Color.white).frame(width: s * 0.6, height: s * 0.42)
                Circle().fill(app.bottom).frame(width: s * 0.26, height: s * 0.26)
                Circle().fill(Color.white).frame(width: s * 0.12, height: s * 0.12)
            }
        case .mail:
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.06).fill(Color.white).frame(width: s * 0.6, height: s * 0.42)
                PathShape { size in
                    var p = Path()
                    p.move(to: Point(x: 0, y: 0))
                    p.addLine(to: Point(x: size.width / 2, y: size.height))
                    p.addLine(to: Point(x: size.width, y: 0))
                    p.closeSubpath()
                    return p
                }
                .fill(app.bottom)
                .frame(width: s * 0.5, height: s * 0.22)
                .padding(.bottom, s * 0.2)
            }
        case .clock:
            ZStack {
                Circle().fill(Color.white).frame(width: s * 0.66, height: s * 0.66)
                Rectangle().fill(Color.black).frame(width: s * 0.04, height: s * 0.26)
                    .padding(.bottom, s * 0.24)
                Rectangle().fill(Color.black).frame(width: s * 0.04, height: s * 0.2)
                    .rotationEffect(.init(degrees: 110), anchor: .top)
                    .padding(.top, s * 0.2)
                Circle().fill(Color(hex: 0xFF9500)).frame(width: s * 0.06, height: s * 0.06)
            }
        case .photos:
            ZStack {
                ForEach(0..<8) { i in
                    let a = Double(i) / 8 * 2 * Double.pi
                    Circle()
                        .fill([Color(hex: 0xFF3B30), Color(hex: 0xFF9500), Color(hex: 0xFFCC00), Color(hex: 0x34C759),
                               Color(hex: 0x00C7BE), Color(hex: 0x007AFF), Color(hex: 0x5856D6), Color(hex: 0xFF2D55)][i].opacity(0.85))
                        .frame(width: s * 0.3, height: s * 0.3)
                        .offset(x: cos(a) * s * 0.17, y: sin(a) * s * 0.17)
                }
            }
        case .weather:
            ZStack {
                Circle().fill(Color(hex: 0xFFD60A)).frame(width: s * 0.3, height: s * 0.3)
                    .padding(EdgeInsets(leading: s * 0.2, bottom: s * 0.2))
                Capsule().fill(Color.white).frame(width: s * 0.56, height: s * 0.24)
                    .padding(.top, s * 0.14)
                Circle().fill(Color.white).frame(width: s * 0.28, height: s * 0.28)
                    .padding(EdgeInsets(top: s * 0.0, trailing: s * 0.08))
            }
        case .settings:
            ZStack {
                Circle().stroke(Color.white, lineWidth: s * 0.12).frame(width: s * 0.5, height: s * 0.5)
                ForEach(0..<8) { i in
                    RoundedRectangle(cornerRadius: s * 0.02).fill(Color.white)
                        .frame(width: s * 0.12, height: s * 0.7)
                        .rotationEffect(.init(degrees: Double(i) * 22.5))
                        .opacity(i % 2 == 0 ? 1 : 0)
                }
                Circle().fill(app.bottom).frame(width: s * 0.5, height: s * 0.5)
                Circle().stroke(Color.white, lineWidth: s * 0.12).frame(width: s * 0.5, height: s * 0.5)
                Circle().fill(app.bottom).frame(width: s * 0.2, height: s * 0.2)
            }
        case .maps:
            ZStack {
                Rectangle().fill(Color(hex: 0xF5F5F0)).frame(width: s, height: s * 0.5)
                    .padding(.top, s * 0.5)
                Rectangle().fill(Color(hex: 0xFFD54F)).frame(width: s * 0.1, height: s)
                    .rotationEffect(.init(degrees: 25))
                Circle().fill(Color(hex: 0xFF3B30)).frame(width: s * 0.26, height: s * 0.26)
                    .padding(.bottom, s * 0.14)
                Circle().fill(Color.white).frame(width: s * 0.1, height: s * 0.1)
                    .padding(.bottom, s * 0.14)
            }
            .cornerRadius(s * 0.23)
        case .notes:
            VStack(spacing: 0) {
                Rectangle().fill(app.bottom).frame(height: s * 0.24)
                VStack(spacing: s * 0.1) {
                    Rectangle().fill(Color(hex: 0xD1D1D6)).frame(width: s * 0.6, height: s * 0.04)
                    Rectangle().fill(Color(hex: 0xD1D1D6)).frame(width: s * 0.6, height: s * 0.04)
                    Rectangle().fill(Color(hex: 0xD1D1D6)).frame(width: s * 0.4, height: s * 0.04)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            }
            .cornerRadius(s * 0.23)
        case .safari:
            ZStack {
                Circle().fill(Color.white).frame(width: s * 0.72, height: s * 0.72)
                Circle().fill(app.bottom).frame(width: s * 0.64, height: s * 0.64)
                ForEach(0..<12) { i in
                    Rectangle().fill(Color.white.opacity(0.8))
                        .frame(width: s * 0.02, height: s * 0.64)
                        .rotationEffect(.init(degrees: Double(i) * 15))
                        .opacity(i % 3 == 0 ? 1 : 0.5)
                }
                Circle().fill(app.bottom).frame(width: s * 0.54, height: s * 0.54)
                Rectangle().fill(Color(hex: 0xFF3B30)).frame(width: s * 0.08, height: s * 0.26)
                    .padding(.bottom, s * 0.26)
                    .rotationEffect(.init(degrees: 45))
                Rectangle().fill(Color.white).frame(width: s * 0.08, height: s * 0.26)
                    .padding(.top, s * 0.26)
                    .rotationEffect(.init(degrees: 45))
            }
        }
    }
}

@View
struct IconWithLabel {
    let app: AppIcon
    var thickness: Double = 8
    var isGlass: Bool = true

    var body: some View {
        // The icon view carries its glass margin; the label sits under the
        // icon itself.
        VStack(spacing: -18) {
            IconView(app: app, thickness: thickness, isGlass: isGlass)
            Text(app.id)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
        .frame(width: 112)
    }
}

// MARK: - Wallpaper

@View
struct Wallpaper {
    var body: some View {
        ZStack {
            Rectangle().fill(.linearGradient(
                colors: [Color(hex: 0x1B1F3B), Color(hex: 0x2A1D4E), Color(hex: 0x0E1226)],
                startPoint: .top,
                endPoint: .bottom
            ))
            // Offsets draw elsewhere without growing the layout.
            Circle().fill(Color(hex: 0x3A2E7A).opacity(0.35)).frame(width: 520, height: 520)
                .offset(x: 260, y: 200)
            Circle().fill(Color(hex: 0x1F5E8C).opacity(0.25)).frame(width: 360, height: 360)
                .offset(x: -300, y: -160)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Screen

@View
struct HomeScreen {
    @State private var isGlass = true
    @State private var taps = 0
    @State private var thickness = 8.0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()

            // The icons, each its own glass.
            VStack(spacing: 0) {
                ForEach(0..<2) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<6) { column in
                            IconWithLabel(app: apps[row * 6 + column], thickness: thickness, isGlass: isGlass)
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 110, leading: 90))

            // Toolbar: buttons on one glass bar.
            HStack(spacing: 6) {
                Button("Tap \(taps)") { taps += 1 }
                Button("Thicker") { thickness = min(16, thickness + 1) }
                Button("Thinner") { thickness = max(1, thickness - 1) }
                Button(isGlass ? "Glass off" : "Glass on") { isGlass.toggle() }
            }
            .tint(.clear)
            .font(.system(size: 15, weight: .medium))
            .padding(horizontal: 10, vertical: 6)
            .liquidGlass(cornerRadius: 24, thickness: 5, isEnabled: isGlass)
            .padding(EdgeInsets(top: 36, leading: 70))

            Text("\(Int(thickness))pt")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .padding(horizontal: 18, vertical: 12)
                .liquidGlass(cornerRadius: 22, thickness: 5, isEnabled: isGlass)
                .padding(EdgeInsets(top: 36, leading: 560))

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LiquidGlassApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Liquid glass — PyShader × NucleantSwiftUI", width: 900, height: 620) {
            HomeScreen()
        }
    }
}

LiquidGlassApp.main()
