// UninstallCheck.swift — the matching rules, written to falsify. The dangerous failure here
// is a substring match eating a shared folder, so that is what these prove cannot happen.
import AppKit
import Foundation

enum UninstallCheck {
    @MainActor static func run(_ c: CheckSuite) async {
        await quitChecks(c)
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
        // These two live under ~/Library/Application Support because the matcher looks
        // there, so they DO have to go — but into the system temp area, not the user's Bin.
        defer {
            let tmp = NSTemporaryDirectory()
            try? fm.moveItem(atPath: shared, toPath: tmp + "pc-check-shared-\(UUID().uuidString)")
            try? fm.moveItem(atPath: mine, toPath: tmp + "pc-check-mine-\(UUID().uuidString)")
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

extension UninstallCheck {
    /// Quitting an app so it can be uninstalled. The guards matter more than the feature:
    /// force-quitting the wrong thing costs unsaved work, and for a video editor that is
    /// hours of it.
    @MainActor static func quitChecks(_ c: CheckSuite) async {
        func app(_ name: String, _ id: String, running: Bool = true,
                 system: Bool = false, formula: Bool = false) -> InstalledApp {
            InstalledApp(name: name, bundleID: id, path: "/Applications/\(name).app",
                         bytes: 0, isRunning: running, isSystem: system,
                         origin: formula ? .formula : .bundle)
        }
        // the blocker the user can clear
        c.check("quit: a running third-party app is offered a quit",
                Uninstaller.blockedOnlyByRunning(app("Sloth", "com.sveinbjorn.Sloth")))
        c.check("quit: an app that is not running needs no quit",
                !Uninstaller.blockedOnlyByRunning(app("Sloth", "com.sveinbjorn.Sloth", running: false)))
        // and the refusals that no amount of quitting lifts
        c.check("quit: an Apple app is never offered a quit",
                !Uninstaller.blockedOnlyByRunning(app("Safari", "com.apple.Safari", system: true)))
        c.check("quit: Performac will not be quit to uninstall itself",
                !Uninstaller.blockedOnlyByRunning(app("Performac", "com.chris.performac.v2")))
        c.check("quit: a formula has no process to quit",
                !Uninstaller.blockedOnlyByRunning(app("ffmpeg", "brew:ffmpeg", formula: true)))

        // bundle id, not display name: a name can collide, an id cannot
        // com.apple.finder is lowercase and com.apple.Safari is not; both must be refused
        c.check("quit: a lowercase Apple id is recognised", Uninstaller.isApple("com.apple.finder"))
        c.check("quit: a mixed-case Apple id is recognised", Uninstaller.isApple("com.apple.Safari"))
        c.check("quit: a lookalike id is not treated as Apple",
                !Uninstaller.isApple("com.appleseed.MyApp"))
        // a Safari web app is the user's own, despite the Apple prefix
        c.check("quit: a Safari web app is not treated as part of macOS",
                !Uninstaller.isApple("com.apple.Safari.WebApp.B9F61036-2F21-492A-9A70-E98367E0D057"))
        c.check("quit: Safari itself still is",
                Uninstaller.isApple("com.apple.Safari"))
        switch ProcessControl.target(bundleID: "com.apple.finder", fallbackName: "Finder") {
        case .failure(let why): c.check("quit: Finder is refused as system-critical",
                                        why == .systemCritical)
        case .success: c.check("quit: Finder is refused as system-critical", false)
        }
        switch ProcessControl.target(bundleID: "com.example.not.running", fallbackName: "Nope") {
        case .failure(let why): c.check("quit: an app that is not running reports gone",
                                        why == .gone)
        case .success: c.check("quit: an app that is not running reports gone", false)
        }
        // this app is running right now, and must refuse to be targeted
        let selfID = Bundle.main.bundleIdentifier ?? "com.chris.performac.v2"
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == selfID }) {
            if case .success = ProcessControl.target(bundleID: selfID, fallbackName: "Performac") {
                c.check("quit: Performac refuses to target itself", false)
            } else {
                c.check("quit: Performac refuses to target itself", true)
            }
        }

        // waitForExit must report honestly on a pid that is definitely gone, and on one that
        // is definitely not — it gates whether files start being removed
        let dead = ProcessControl.Target(pid: 999_999, name: "gone", isApp: false, hasWindows: false)
        c.check("quit: a dead process is seen to have exited",
                await ProcessControl.waitForExit(dead, timeout: 0.5))
        let mine = ProcessControl.Target(pid: getpid(), name: "self", isApp: false, hasWindows: false)
        c.check("quit: a live process is not reported as exited",
                !(await ProcessControl.waitForExit(mine, timeout: 0.5)))
    }
}
