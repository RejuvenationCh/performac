// UninstallCheck.swift — the matching rules, written to falsify. The dangerous failure here
// is a substring match eating a shared folder, so that is what these prove cannot happen.
import Foundation

enum UninstallCheck {
    @MainActor static func run(_ c: CheckSuite) async {
        let fm = FileManager.default
        let lib = NSHomeDirectory() + "/Library"

        // Apple apps and Performac itself are refused before anything is scanned.
        let apple = InstalledApp(name: "Safari", bundleID: "com.apple.Safari", path: "/x",
                                 bytes: 0, isRunning: false, isSystem: true)
        c.check("uninstall: Apple apps refused", Uninstaller.refusal(for: apple) != nil)
        let me = InstalledApp(name: "Performac", bundleID: "com.chris.performac.v2", path: "/x",
                              bytes: 0, isRunning: false, isSystem: false)
        c.check("uninstall: refuses to uninstall itself", Uninstaller.refusal(for: me) != nil)
        let live = InstalledApp(name: "Zen", bundleID: "app.zen", path: "/x",
                                bytes: 0, isRunning: true, isSystem: false)
        c.check("uninstall: running app refused until quit", Uninstaller.refusal(for: live) != nil)
        let ok = InstalledApp(name: "Thing", bundleID: "com.x.thing", path: "/x",
                              bytes: 0, isRunning: false, isSystem: false)
        c.check("uninstall: ordinary quit app is allowed", Uninstaller.refusal(for: ok) == nil)

        // THE important one: a shared parent folder must never be matched by a longer app name.
        let appSupport = lib + "/Application Support"
        let shared = appSupport + "/PerformacCheckVendor"
        let mine = appSupport + "/PerformacCheckVendor Studio"
        try? fm.createDirectory(atPath: shared, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: mine, withIntermediateDirectories: true)
        defer {
            try? fm.trashItem(at: URL(fileURLWithPath: shared), resultingItemURL: nil)
            try? fm.trashItem(at: URL(fileURLWithPath: mine), resultingItemURL: nil)
        }
        let child = InstalledApp(name: "PerformacCheckVendor Studio", bundleID: "com.pcv.studio",
                                 path: "/x", bytes: 0, isRunning: false, isSystem: false)
        let found = Uninstaller.leftovers(for: child).map(\.path)
        c.check("uninstall: finds its own exactly-named folder", found.contains(mine))
        c.check("uninstall: NEVER matches the shared parent folder", !found.contains(shared))

        // and the reverse: the short-named app must not swallow the longer sibling
        let parent = InstalledApp(name: "PerformacCheckVendor", bundleID: "com.pcv",
                                  path: "/x", bytes: 0, isRunning: false, isSystem: false)
        let found2 = Uninstaller.leftovers(for: parent).map(\.path)
        c.check("uninstall: short name does not swallow longer sibling", !found2.contains(mine))
        c.check("uninstall: short name still finds itself", found2.contains(shared))

        // bundle-id matches are marked certain, name matches are not
        let byName = Uninstaller.leftovers(for: child).first { $0.path == mine }
        c.check("uninstall: name match flagged as weaker", byName?.byBundleID == false)
    }
}
