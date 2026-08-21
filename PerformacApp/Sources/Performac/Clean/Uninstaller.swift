// Uninstaller.swift — find an app and everything it left behind.
//
// Matching is EXACT, never substring. "Adobe Premiere Pro" must never match the folder
// ~/Library/Application Support/Adobe, which holds presets and settings for every Adobe app
// on the machine. Substring matching is how uninstallers eat data that was not theirs.
//
// Removal goes through Trash.moveToTrash like everything else, so an over-eager selection
// is always recoverable.
import AppKit
import Foundation

struct InstalledApp: Identifiable, Sendable {
    var id: String { bundleID }
    var name: String
    var bundleID: String
    var path: String
    var bytes: Int64
    var isRunning: Bool
    /// Apple's own apps are never offered: removing them breaks the OS and they reinstall.
    var isSystem: Bool
}

struct Leftover: Identifiable, Sendable {
    var id: String { path }
    var path: String
    var bytes: Int64
    var category: String
    /// Bundle-id matches are certain. Name matches are plausible — shown, but flagged.
    var byBundleID: Bool
    var selected: Bool = true
}

enum Uninstaller {
    /// Every place a Mac app scatters state. All are inside ~/Library: anything under
    /// /Library needs admin rights, which this app deliberately never asks for.
    private static let places: [(dir: String, label: String)] = [
        ("Application Support", "Application Support"),
        ("Caches", "Caches"),
        ("Preferences", "Preferences"),
        ("Containers", "Container"),
        ("Group Containers", "Group Container"),
        ("Saved Application State", "Saved State"),
        ("Logs", "Logs"),
        ("HTTPStorages", "Web Storage"),
        ("WebKit", "WebKit Data"),
        ("Cookies", "Cookies"),
        ("LaunchAgents", "Launch Agent"),
        ("Application Scripts", "App Scripts"),
    ]

    static func installedApps() -> [InstalledApp] {
        let fm = FileManager.default
        var out: [InstalledApp] = []
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where name.hasSuffix(".app") {
                let path = root + "/" + name
                guard let b = Bundle(path: path), let id = b.bundleIdentifier else { continue }
                let display = (name as NSString).deletingPathExtension
                out.append(InstalledApp(
                    name: display, bundleID: id, path: path,
                    bytes: directorySize(path),
                    isRunning: running.contains(id),
                    isSystem: id.hasPrefix("com.apple.")))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Exact matches only: a name or id must equal the entry, or be its filename stem.
    static func leftovers(for app: InstalledApp) -> [Leftover] {
        let fm = FileManager.default
        let lib = NSHomeDirectory() + "/Library"
        var out: [Leftover] = []
        for place in places {
            let dir = lib + "/" + place.dir
            for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let stem = (entry as NSString).deletingPathExtension
                let byID = stem == app.bundleID || entry == app.bundleID
                let byName = stem == app.name || entry == app.name
                guard byID || byName else { continue }
                let p = dir + "/" + entry
                out.append(Leftover(path: p, bytes: directorySize(p),
                                    category: place.label, byBundleID: byID))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Refusals, checked before anything is offered.
    static func refusal(for app: InstalledApp) -> String? {
        if app.isSystem { return "Part of macOS — Performac will not remove Apple's own apps." }
        if app.bundleID == "com.chris.performac.v2" { return "This is Performac." }
        if app.isRunning { return "\(app.name) is running. Quit it first so it does not rewrite its files while being removed." }
        return nil
    }

    static func directorySize(_ path: String) -> Int64 {
        var total: Int64 = 0
        let url = URL(fileURLWithPath: path)
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey],
            options: [], errorHandler: { _, _ in true }) else {
            return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        }
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]),
                  v.isSymbolicLink != true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
