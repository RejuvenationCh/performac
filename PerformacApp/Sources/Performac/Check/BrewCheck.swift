// BrewCheck.swift — the Homebrew inventory, against the real Cellar and Caskroom on this
// machine. These are live-state checks: they assert shape and invariants rather than exact
// package names, which change every time something is installed.
import Foundation

enum BrewCheck {
    @MainActor static func run(_ c: CheckSuite) async {
        guard Brew.prefix != nil else {
            print("SKIP brew: no Homebrew on this machine")
            return
        }
        let f = Brew.formulae()
        c.check("brew: the Cellar produced formulae", !f.isEmpty)
        c.check("brew: every formula carries a version", f.allSatisfy { !$0.version.isEmpty })
        c.check("brew: no formula is listed twice", Set(f.map(\.name)).count == f.count)

        // the split is the whole point of the view: a handful chosen, the rest dragged in
        let requested = f.filter(\.onRequest)
        c.check("brew: both requested and dependency formulae exist",
                !requested.isEmpty && requested.count < f.count)

        // reverse dependencies are inverted from the receipts, so they must be symmetric:
        // anything named as a dependent has to be an installed formula, not a phantom
        let installed = Set(f.map(\.name))
        c.check("brew: every dependent is itself installed",
                f.allSatisfy { $0.dependents.allSatisfy(installed.contains) })
        c.check("brew: nothing depends on itself",
                f.allSatisfy { !$0.dependents.contains($0.name) })
        // a leaf library is depended on; something has to be
        c.check("brew: at least one formula has dependents",
                f.contains { !$0.dependents.isEmpty })

        // a formula with dependents must be refused, and the refusal must name them
        if let needed = f.first(where: { !$0.dependents.isEmpty }) {
            let app = Uninstaller.listApps().first { $0.bundleID == "brew:" + needed.name }
            let refusal = app.flatMap(Uninstaller.refusal(for:)) ?? ""
            c.check("brew: a depended-on formula is refused, naming a dependent",
                    refusal.contains(needed.dependents[0]))
        }
        // and one with none is still refused, because brew owns the keg either way
        if let free = f.first(where: { $0.dependents.isEmpty }) {
            let app = Uninstaller.listApps().first { $0.bundleID == "brew:" + free.name }
            c.check("brew: an unneeded formula is still refused, not trashed",
                    app.flatMap(Uninstaller.refusal(for:)) != nil)
            c.check("brew: the refusal hands over a brew command",
                    app?.uninstallCommand == "brew uninstall " + free.name)
        }

        // formulae reach the Apps list, which is the bug this was written for: ffmpeg has no
        // bundle, so a list built from /Applications alone could never show it
        let apps = Uninstaller.listApps()
        c.check("brew: formulae appear in the app list",
                apps.contains { $0.isFormula })
        c.check("brew: formula ids cannot collide with a bundle id",
                apps.filter(\.isFormula).allSatisfy { $0.bundleID.hasPrefix("brew:") })
        c.check("brew: ids are unique across apps and formulae",
                Set(apps.map(\.id)).count == apps.count)

        // a cask keeps the bundle in /Applications and a record in the Caskroom; the record
        // has to be offered alongside, or brew goes on reporting the app as installed
        let casks = Brew.casksByAppPath()
        if let (path, cask) = casks.first {
            c.check("brew: a cask resolves to a real bundle",
                    FileManager.default.fileExists(atPath: path) && path.hasSuffix(".app"))
            c.check("brew: the cask record is inside the Caskroom",
                    cask.recordPath.contains("/Caskroom/"))
            if let app = apps.first(where: { $0.path == path }) {
                c.check("brew: a cask-installed app knows its cask", app.cask != nil)
                c.check("brew: its Homebrew record is offered as a leftover",
                        Uninstaller.leftovers(for: app).contains { $0.path == cask.recordPath })
            }
        }
    }
}
