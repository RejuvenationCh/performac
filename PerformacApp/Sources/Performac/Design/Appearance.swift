// Appearance.swift — light, dark, or whatever the system is doing.
//
// Kept in UserDefaults rather than the settings table because it has to be applied in
// applicationDidFinishLaunching, before the database is open. A preference that arrives a
// beat late means the window paints light and then flips.
import AppKit

enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match system"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// nil means "inherit", which is how AppKit spells following the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    private static let key = "appearance"

    static var current: Appearance {
        UserDefaults.standard.string(forKey: key).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    @MainActor static func apply(_ a: Appearance) {
        UserDefaults.standard.set(a.rawValue, forKey: key)
        NSApp.appearance = a.nsAppearance
        // The menu bar is the system's, not the app's. Forcing the app dark while the system
        // is light would flip the template glyph to white on a white menu bar, so the status
        // button is explicitly left inheriting from the menu bar it sits in.
        onApply?()
    }

    /// Set by AppDelegate to re-pin the status item after an appearance change.
    @MainActor static var onApply: (() -> Void)?

    @MainActor static func applyStored() { apply(current) }
}
