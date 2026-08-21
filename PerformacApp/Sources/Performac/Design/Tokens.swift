// Tokens.swift — the design system from DESIGN.md, recorded from the Stitch artifact.
// Light values are the artifact's; dark values are the macOS semantic equivalents, because
// a menu bar app that ignores dark mode looks broken at night.
import SwiftUI
import AppKit

private func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
}
private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

enum PC {
    // MARK: surfaces
    static let canvas    = dyn(NSColor(hex: 0xf7f9ff), .windowBackgroundColor)
    static let surface   = dyn(.white,                  .controlBackgroundColor)
    static let fill1     = dyn(NSColor(hex: 0xecf4ff), NSColor(hex: 0x2a2c30))
    static let fill2     = dyn(NSColor(hex: 0xe6effa), NSColor(hex: 0x303338))
    static let fill3     = dyn(NSColor(hex: 0xe0e9f5), NSColor(hex: 0x36393f))
    static let fill4     = dyn(NSColor(hex: 0xdae3ef), NSColor(hex: 0x3d4147))

    // MARK: text
    static let ink       = dyn(NSColor(hex: 0x141c25), .labelColor)
    static let ink2      = dyn(NSColor(hex: 0x434654), .secondaryLabelColor)
    static let meta      = dyn(NSColor(hex: 0x747686), .tertiaryLabelColor)
    static let hairline  = dyn(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.12))

    // MARK: state — the only colours that carry meaning
    static let accent    = dyn(NSColor(hex: 0x0045c5), .controlAccentColor)
    static let accentFill = dyn(NSColor(hex: 0x2f5fe0), .controlAccentColor)
    static let amber     = dyn(NSColor(hex: 0xb24800), .systemOrange)
    static let amberSoft = dyn(NSColor(hex: 0xffe4d9), NSColor(hex: 0xb24800, alpha: 0.22))
    static let red       = dyn(NSColor(hex: 0xba1a1a), .systemRed)
    static let redSoft   = dyn(NSColor(hex: 0xffdad6), NSColor(hex: 0xba1a1a, alpha: 0.22))
    static let green     = dyn(NSColor(hex: 0x0b7052), .systemGreen)
    static let greenSoft = dyn(NSColor(hex: 0xd8f2e7), NSColor(hex: 0x0b7052, alpha: 0.24))
    static let chip      = dyn(NSColor(hex: 0xdfe3eb), NSColor(hex: 0x3a3d43))

    // MARK: geometry (DESIGN.md: deliberately small radii — this is what reads as desktop)
    static let r: CGFloat = 2, rLg: CGFloat = 4, rXl: CGFloat = 8, rPill: CGFloat = 12
    static let s1: CGFloat = 4, s2: CGFloat = 8, gutter: CGFloat = 12, stack: CGFloat = 16
    static let rail: CGFloat = 64
}

// MARK: type scale — SF Pro, sizes recorded from the artifact
extension Font {
    static let pcDisplay  = Font.system(size: 20, weight: .semibold)
    static let pcHeadline = Font.system(size: 16, weight: .semibold)
    static let pcTitle    = Font.system(size: 14, weight: .semibold)
    static let pcBody     = Font.system(size: 13)
    static let pcSmall    = Font.system(size: 12)
    static let pcLabel    = Font.system(size: 11, weight: .medium)
    /// every figure in the app goes through this
    static let pcNum      = Font.system(size: 13).monospacedDigit()
    static let pcNumLg    = Font.system(size: 20, weight: .semibold).monospacedDigit()
}

extension View {
    func pcHairline(_ edge: Edge) -> some View {
        overlay(alignment: edge == .top ? .top : edge == .bottom ? .bottom : edge == .leading ? .leading : .trailing) {
            Rectangle().fill(PC.hairline)
                .frame(width: edge == .leading || edge == .trailing ? 1 : nil,
                       height: edge == .top || edge == .bottom ? 1 : nil)
        }
    }
    /// card: white surface, 4pt radius, hairline border, small shadow
    func pcCard() -> some View {
        background(PC.surface)
            .clipShape(RoundedRectangle(cornerRadius: PC.rLg))
            .overlay(RoundedRectangle(cornerRadius: PC.rLg).stroke(PC.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}


// MARK: - Liquid Glass
//
// Apple's guidance is that Liquid Glass is a material for the layer that FLOATS ABOVE
// content — navigation, toolbars, controls, popovers, sheets. Content itself stays opaque.
// This app is mostly dense tabular data, so glass goes on the rail, the headers, the
// floating controls and the sheets, and never behind a table row, a treemap or a card.
//
// Two rules that matter as much as where it goes:
//   * never stack glass on glass — nested layers read as muddy grey, not depth
//   * group adjacent glass in a GlassEffectContainer so the shapes blend rather than
//     each rendering its own separate refraction
extension View {
    /// Chrome that floats over content: rails, headers, footers, bars.
    func pcGlassChrome() -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: 0))
    }

    /// A floating panel with its own shape: popovers, sheets, detached controls.
    func pcGlassPanel(_ radius: CGFloat = PC.rXl) -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: radius))
    }

    /// Controls the user presses. `.interactive()` gives the press its specular response.
    func pcGlassControl(_ radius: CGFloat = PC.rPill) -> some View {
        self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: radius))
    }
}
