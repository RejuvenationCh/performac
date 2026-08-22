// UpdatesCheck.swift — parsing brew's output. Fixtures are real lines from this machine.
import Foundation

enum UpdatesCheck {
    @MainActor static func run(_ c: CheckSuite) async {
        // real `brew outdated --formula --verbose` output
        let formulaText = """
        aom (3.13.3) < 3.14.1
        ca-certificates (2025-12-02, 2026-03-19, 2026-05-14, 2026-07-16) < 2026-08-13
        yt-dlp (2026.7.4) < 2026.8.19
        """
        let f = Updates.parse(formulaText, kind: .formula)
        c.check("updates: every formula line parsed", f.count == 3)
        let yt = f.first { $0.name == "yt-dlp" }
        c.check("updates: name, installed and available all read",
                yt?.installed == "2026.7.4" && yt?.available == "2026.8.19")
        // a package installed several times lists them all; the newest is what to compare
        c.check("updates: multi-version install reports the newest installed",
                f.first { $0.name == "ca-certificates" }?.installed == "2026-07-16")
        c.check("updates: formula upgrade command", yt?.upgradeCommand == "brew upgrade yt-dlp")

        // casks use != rather than <
        let caskText = """
        aldente (1.36.3) != 1.38.1
        claude-code (2.1.220) != 2.1.231
        """
        let k = Updates.parse(caskText, kind: .cask)
        c.check("updates: cask lines use != and still parse", k.count == 2)
        c.check("updates: cask upgrade command differs",
                k.first?.upgradeCommand == "brew upgrade --cask aldente")

        // junk must be skipped, never guessed at
        c.check("updates: unparseable lines are dropped",
                Updates.parse("garbage\\n\\nalso garbage", kind: .formula).isEmpty)
        c.check("updates: a line with no available version is dropped",
                Updates.parse("thing (1.0) <", kind: .formula).isEmpty)
        c.check("updates: empty input is empty output",
                Updates.parse("", kind: .formula).isEmpty)
        c.check("updates: results are sorted by name",
                f.map { $0.name } == f.map { $0.name }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }
}
