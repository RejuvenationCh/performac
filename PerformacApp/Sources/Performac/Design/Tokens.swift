// Tokens.swift: the design system. DESIGN.md documents it; this file is the source of truth
// for the values.
//
// The blue-tinted web ground and hardcoded accent are gone in favour of neutral macOS greys
// and the system accent colour, so the app matches whatever accent the user picked in System
// Settings instead of shipping its own blue.
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
    // which both resolve to #1E1E1E in dark aqua, identical. This whole layout is cards on a
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

    // MARK: state, the only colours that carry meaning
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

    // MARK: geometry (DESIGN.md: deliberately small radii, this is what reads as desktop)
    static let r: CGFloat = 2, rLg: CGFloat = 4, rXl: CGFloat = 8, rPill: CGFloat = 12
    static let s1: CGFloat = 4, s2: CGFloat = 8, gutter: CGFloat = 12, stack: CGFloat = 16
    static let s5: CGFloat = 24, s6: CGFloat = 32
    // 76, not 64: at the 11pt label floor, "Duplicates" is the longest rail title and needs
    // this much width to avoid truncating: the rail follows the label, not the other way round.
    static let rail: CGFloat = 76
}

// MARK: type scale, SF Pro. Six steps, nothing below 11pt: smaller than that is under any
// macOS system text size, which is where the 9pt rail labels went wrong.
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
// content: navigation, popovers, sheets. Content itself stays opaque. Headers and toolbars
// looked like they qualified too, but they don't: nothing scrolls under this app's title rows
// or toolbars, so the glass there sat on an opaque canvas and read as a flat tint, not depth.
// Worse, `.bordered`/`.borderedProminent` buttons ARE Liquid Glass on macOS 26, so glass chrome
// wrapped around them was glass stacked on glass. So glass now goes in exactly two places:
//   * the 76pt rail: a sidebar at the window edge is Apple's own glass pattern
//   * sheets (TrashSheet, RowTrashSheet, RowInfoSheet, QuitSheet): they genuinely float above
//     the content behind them
// Never on a title row, a toolbar, a table row, a card or the treemap.
//
// Two rules that matter as much as where it goes:
//   * never stack glass on glass: nested layers read as muddy grey, not depth
//   * group adjacent glass in a GlassEffectContainer so the shapes blend rather than
//     each rendering its own separate refraction
// MARK: - FileKind colour
//
// The taxonomy itself lives in Core/FileKind.swift (engine code, no SwiftUI dependency);
// this is presentation only. Five muted pastels plus audio, all light enough that the
// treemap's black tile labels (DESIGN.md) stay legible on every one of them.
extension FileKind {
    var color: Color {
        switch self {
        case .video: Color(red: 0.72, green: 0.71, blue: 0.94)
        case .image: Color(red: 0.55, green: 0.80, blue: 0.66)
        case .audio: Color(red: 0.94, green: 0.70, blue: 0.75)
        case .cache: Color(red: 0.96, green: 0.83, blue: 0.58)
        case .document: Color(red: 0.62, green: 0.78, blue: 0.94)
        case .other: Color(red: 0.80, green: 0.82, blue: 0.86)
        }
    }
}

// Liquid Glass is macOS 26 only, and requiring 26 for it put the whole app out of reach of
// almost everyone: the build failed on an older Mac before it could produce an .app at all.
// These were the only three 26-only calls in the codebase, so guarding them drops the floor
// to macOS 14 and costs nothing on 26, where the glass still renders.
//
// The fallbacks are not placeholders. Below 26 these surfaces become opaque, which is exactly
// what the rest of the app already does for anything that is not floating above content.
extension View {
    /// Chrome at the window edge: the rail.
    @ViewBuilder
    func pcGlassChrome() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            self.background(PC.surface)
        }
    }

    /// A panel that genuinely floats: every sheet.
    @ViewBuilder
    func pcGlassPanel(_ radius: CGFloat = PC.rXl) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            self.background(PC.surface, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}
