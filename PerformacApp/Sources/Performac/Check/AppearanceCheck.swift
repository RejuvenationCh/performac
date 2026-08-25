// AppearanceCheck.swift — the tokens resolved under both appearances.
//
// These exist because dark mode had one real failure and it was invisible in the source: the
// semantic pair .windowBackgroundColor / .controlBackgroundColor both resolve to #1E1E1E in
// dark aqua. The whole layout is cards on a ground, so every card vanished into the page.
// A check that only read the code could not have caught it — these resolve the colours.
import AppKit
import SwiftUI

enum AppearanceCheck {
    /// Relative luminance, so "is this a step lighter" is a number rather than a judgement.
    private static func lum(_ c: Color, _ named: NSAppearance.Name) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSAppearance(named: named)?.performAsCurrentDrawingAppearance {
            (NSColor(c).usingColorSpace(.sRGB) ?? .black).getRed(&r, green: &g, blue: &b, alpha: &a)
        }
        // flattened against the ground it sits on, so alpha-based tokens compare honestly
        let base: CGFloat = named == .darkAqua ? 0.09 : 0.97
        let f = { (v: CGFloat) in v * a + base * (1 - a) }
        return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    }

    @MainActor static func run(_ c: CheckSuite) async {
        for mode in [NSAppearance.Name.aqua, .darkAqua] {
            let tag = mode == .darkAqua ? "dark" : "light"
            let canvas = lum(PC.canvas, mode), surface = lum(PC.surface, mode)

            // the defect: a card the same colour as the page it sits on
            c.check("appearance/\(tag): a card is distinguishable from the page",
                    abs(surface - canvas) > 0.008,
                    "canvas \(canvas), surface \(surface)")

            // the fill ladder is what tiles and hover states are built from; it has to step
            // consistently away from the card, in whichever direction that mode runs
            let fills = [PC.fill1, PC.fill2, PC.fill3, PC.fill4].map { lum($0, mode) }
            let rising = mode == .darkAqua
            c.check("appearance/\(tag): the fill ladder is monotonic",
                    zip(fills, fills.dropFirst()).allSatisfy { rising ? $1 > $0 : $1 < $0 },
                    "\(fills)")
            c.check("appearance/\(tag): the first fill reads against the card",
                    abs(fills[0] - surface) > 0.008)

            // text has to survive on the surface it is printed on
            for (name, token) in [("ink", PC.ink), ("ink2", PC.ink2), ("meta", PC.meta)] {
                c.check("appearance/\(tag): \(name) contrasts with the card",
                        abs(lum(token, mode) - surface) > 0.10)
            }
            // severity colours are the only ones carrying meaning; they must stay legible
            for (name, token) in [("amber", PC.amber), ("red", PC.red), ("green", PC.green)] {
                c.check("appearance/\(tag): \(name) contrasts with the card",
                        abs(lum(token, mode) - surface) > 0.05)
            }
        }

        // light and dark must actually be different, or a token silently lost its pair
        for (name, token) in [("canvas", PC.canvas), ("surface", PC.surface), ("ink", PC.ink),
                              ("fill1", PC.fill1), ("chip", PC.chip)] {
            c.check("appearance: \(name) has a distinct dark value",
                    abs(lum(token, .aqua) - lum(token, .darkAqua)) > 0.10)
        }

        c.eq("appearance: matching the system means inheriting", Appearance.system.nsAppearance, nil)
        c.eq("appearance: light maps to aqua", Appearance.light.nsAppearance?.name, .aqua)
        c.eq("appearance: dark maps to darkAqua", Appearance.dark.nsAppearance?.name, .darkAqua)
        c.eq("appearance: an unknown stored value falls back to the system",
             Appearance(rawValue: "sepia") ?? .system, .system)
    }
}
