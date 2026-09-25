// Appearance.swift: light, dark, or whatever the system is doing.
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
    }

    @MainActor static func applyStored() { apply(current) }
}
