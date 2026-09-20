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

/// A .app bundle, or a Homebrew formula — a command-line tool like ffmpeg has no bundle
/// and so never appeared in a list built from /Applications, which is exactly why it was
/// invisible here while sitting on hundreds of megabytes.
enum AppOrigin: String, Sendable { case bundle, formula }

struct InstalledApp: Identifiable, Sendable {
    var id: String { bundleID }
    var name: String
    /// For a formula this is `brew:<name>` — a formula has no bundle id, and the list needs
    /// keys that cannot collide with a real one.
    var bundleID: String
    var path: String
    var bytes: Int64
    var isRunning: Bool
    /// Apple's own apps are never offered: removing them breaks the OS and they reinstall.
    var isSystem: Bool
    var origin: AppOrigin = .bundle
    var version: String = ""
    /// Set when a bundle was installed by a cask, so its Homebrew record can go with it.
    var cask: BrewCask? = nil
    /// Formulae only: false means it arrived as somebody else's dependency.
    var onRequest: Bool = true
    /// Formulae only: installed packages that need this one.
    var dependents: [String] = []
    var installedAt: Date? = nil

    var isFormula: Bool { origin == .formula }
    var subtitle: String {
        origin == .formula ? "Homebrew formula · \(version)" : bundleID
    }
    var uninstallCommand: String {
        if origin == .formula { return "brew uninstall \(name)" }
        if let c = cask { return "brew uninstall --cask \(c.token)" }
        return ""
    }
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

    /// Names, ids and running state only — no directory walking, so this is instant.
    static func listApps() -> [InstalledApp] {
        let fm = FileManager.default
        var out: [InstalledApp] = []
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let casks = Brew.casksByAppPath()
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where name.hasSuffix(".app") {
                let path = root + "/" + name
                guard let b = Bundle(path: path), let id = b.bundleIdentifier else { continue }
                out.append(InstalledApp(
                    name: (name as NSString).deletingPathExtension, bundleID: id, path: path,
                    bytes: 0, isRunning: running.contains(id), isSystem: Self.isApple(id),
                    version: (b.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "",
                    cask: casks[path]))
            }
        }
        out += Brew.formulae().map(row)
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A formula has no bundle, no bundle id and cannot be running as an app, so most of the
    /// app fields are simply absent rather than faked.
    private static func row(_ f: BrewFormula) -> InstalledApp {
        InstalledApp(name: f.name, bundleID: "brew:" + f.name, path: f.path,
                     bytes: f.bytes, isRunning: false, isSystem: false,
                     origin: .formula, version: f.version,
                     onRequest: f.onRequest, dependents: f.dependents,
                     installedAt: f.installedAt)
    }

    /// The expensive half: walks each bundle. Call this off the main actor.
    static func withSizes(_ apps: [InstalledApp]) -> [InstalledApp] {
        apps.map { a in
            var c = a
            c.bytes = directorySize(a.path)
            return c
        }.sorted { $0.bytes > $1.bytes }
    }

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
                    isSystem: Self.isApple(id)))
            }
        }
        out += Brew.formulae().map { var r = row($0); r.bytes = directorySize($0.path); return r }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Exact matches only: a name or id must equal the entry, or be its filename stem.
    static func leftovers(for app: InstalledApp) -> [Leftover] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let lib = home + "/Library"
        var out: [Leftover] = []

        // A command-line tool keeps nothing in ~/Library; it uses the dotfile directories.
        if app.isFormula {
            for (dir, label) in [(".config", "Config"), (".cache", "Cache"),
                                 (".local/share", "Local Data")] {
                let full = home + "/" + dir
                for entry in (try? fm.contentsOfDirectory(atPath: full)) ?? []
                where entry == app.name || (entry as NSString).deletingPathExtension == app.name {
                    let pth = full + "/" + entry
                    out.append(Leftover(path: pth, bytes: directorySize(pth),
                                        category: label, byBundleID: true))
                }
            }
            return out.sorted { $0.bytes > $1.bytes }
        }

        // A cask keeps the bundle in /Applications and a record in the Caskroom. Trashing
        // only the bundle leaves brew reporting the app as still installed.
        if let c = app.cask {
            out.append(Leftover(path: c.recordPath, bytes: directorySize(c.recordPath),
                                category: "Homebrew record", byBundleID: true))
        }
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

    /// Apple is inconsistent about the casing of its own bundle ids — Finder is
    /// com.apple.finder, Safari is com.apple.Safari — and a case-sensitive prefix test would
    /// have offered to uninstall Finder.
    static func isApple(_ bundleID: String) -> Bool {
        let low = bundleID.lowercased()
        // A Safari web app is the user's own shortcut wearing an Apple bundle id. Treating it
        // as part of macOS refused to remove three apps on this machine that Chris made
        // himself — and he has already had to delete one of them by hand.
        if low.hasPrefix("com.apple.safari.webapp.") { return false }
        return low.hasPrefix("com.apple.")
    }

    /// True when the only thing standing between this app and removal is that it is running —
    /// a blocker the user can clear, as opposed to a refusal that will never lift.
    static func blockedOnlyByRunning(_ app: InstalledApp) -> Bool {
        guard !app.isFormula, !app.isSystem, app.isRunning else { return false }
        return app.bundleID != "com.chris.performac.v2"
    }

    /// Refusals, checked before anything is offered.
    static func refusal(for app: InstalledApp) -> String? {
        if app.isFormula {
            if !app.dependents.isEmpty {
                let names = app.dependents.prefix(4).joined(separator: ", ")
                let more = app.dependents.count > 4 ? " and \(app.dependents.count - 4) more" : ""
                return "\(app.dependents.count) installed package\(app.dependents.count == 1 ? "" : "s") "
                     + "need \(app.name): \(names)\(more). Removing it would break them."
            }
            return "Homebrew owns this one. Performac can only move things to the Trash, and "
                 + "pulling a keg out from under brew leaves it broken — run the command below instead."
        }
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
