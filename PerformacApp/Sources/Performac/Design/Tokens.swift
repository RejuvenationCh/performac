// Tokens.swift — the design system from DESIGN.md, recorded from the Stitch artifact.
// Repalette pass: the blue-tinted web ground and hardcoded accent are gone in favour of
// neutral macOS greys and the system accent colour, so the app matches whatever accent
// the user picked in System Settings instead of shipping its own blue.
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
    //
    // The dark values are explicit rather than .windowBackgroundColor / .controlBackgroundColor,
    // which both resolve to #1E1E1E in dark aqua — identical. This whole layout is cards on a
    // ground, so the semantic pair made every card disappear into the page with only a hairline
    // left to find it. These keep the light relationship (the card sits a step above the ground)
    // and continue the fill ladder stepping monotonically away from `surface`.
    static let canvas    = dyn(NSColor(hex: 0xF5F5F7), NSColor(hex: 0x1A1A1C))
    static let surface   = dyn(.white,                 NSColor(hex: 0x242426))
    static let fill1     = dyn(NSColor(hex: 0xEFEFF2), NSColor(hex: 0x2C2C2F))
    static let fill2     = dyn(NSColor(hex: 0xE8E8ED), NSColor(hex: 0x333336))
    static let fill3     = dyn(NSColor(hex: 0xDFDFE4), NSColor(hex: 0x3A3A3E))
    static let fill4     = dyn(NSColor(hex: 0xD6D6DC), NSColor(hex: 0x424247))

    // MARK: text
    static let ink       = dyn(NSColor(hex: 0x1D1D1F), .labelColor)
    static let ink2      = dyn(NSColor(hex: 0x48484A), .secondaryLabelColor)
    static let meta      = dyn(NSColor(hex: 0x8E8E93), .tertiaryLabelColor)
    static let hairline  = dyn(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.12))

    // MARK: state — the only colours that carry meaning
    // The central native move: the app's own accent is gone, so it matches whatever the user
    // picked in System Settings instead of shipping a hardcoded blue.
    static let accent    = dyn(.controlAccentColor, .controlAccentColor)
    static let accentFill = dyn(.controlAccentColor, .controlAccentColor)
    static let amber     = dyn(.systemOrange, .systemOrange)
    static let amberSoft = dyn(NSColor.systemOrange.withAlphaComponent(0.14), NSColor.systemOrange.withAlphaComponent(0.22))
    static let red       = dyn(.systemRed, .systemRed)
    static let redSoft   = dyn(NSColor.systemRed.withAlphaComponent(0.14), NSColor.systemRed.withAlphaComponent(0.22))
    static let green     = dyn(.systemGreen, .systemGreen)
    static let greenSoft = dyn(NSColor.systemGreen.withAlphaComponent(0.14), NSColor.systemGreen.withAlphaComponent(0.22))
    static let chip      = dyn(NSColor(hex: 0xE4E4E9), NSColor(hex: 0x35353A))
    static let cardShadow = dyn(NSColor(white: 0, alpha: 0.05), NSColor(white: 0, alpha: 0.30))
    /// shadcn's focus treatment, borrowed for pass 2 — not wired to anything yet.
    static let focusRing = dyn(NSColor.controlAccentColor.withAlphaComponent(0.55),
                              NSColor.controlAccentColor.withAlphaComponent(0.70))

    // MARK: geometry (DESIGN.md: deliberately small radii — this is what reads as desktop)
    static let r: CGFloat = 2, rLg: CGFloat = 4, rXl: CGFloat = 8, rPill: CGFloat = 12
    static let s1: CGFloat = 4, s2: CGFloat = 8, gutter: CGFloat = 12, stack: CGFloat = 16
    static let s5: CGFloat = 24, s6: CGFloat = 32
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
            // a black shadow does nothing on a dark ground; the surface step and the hairline
            // carry the separation there
            .shadow(color: PC.cardShadow, radius: 1, y: 1)
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
