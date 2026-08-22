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
        // major-version detection decides what gets flagged before an irreversible action
        func item(_ n: String, _ a: String, _ b: String) -> OutdatedItem {
            OutdatedItem(name: n, installed: a, available: b, kind: .formula)
        }
        c.check("major: ffmpeg 8 to 9 is a major jump", item("ffmpeg", "8.1_1", "9.0.1").isMajorJump)
        c.check("major: a minor bump is not", !item("aom", "3.13.3", "3.14.1").isMajorJump)
        // yt-dlp versions are dates; 2026.7 to 2026.8 must not be called a major change
        c.check("major: a date-versioned package is never a major jump",
                !item("yt-dlp", "2026.7.4", "2026.8.19").isMajorJump)
        c.check("major: a date year rolling over is still not a major jump",
                !item("yt-dlp", "2025.12.1", "2026.1.1").isMajorJump)
        c.check("major: equal majors are not a jump", !item("x", "2.1", "2.9").isMajorJump)
        c.check("major: unparseable versions do not claim a jump", !item("x", "abc", "def").isMajorJump)
        c.check("updates: rows are selected by default", item("x", "1.0", "2.0").selected)

        // real output from the zulu@17 run: a cask with a pkg payload only root can replace
        let sudoFailure = """
        ==> Uninstalling packages with `sudo` (which may request your password)...
        com.azulsystems.zulu.17
        sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
        sudo: a password is required
        Error: zulu@17: Failure while executing; `/usr/bin/sudo -u root -E -- /usr/bin/xargs -0 -- /bin/rm --` exited with 1.
        """
        c.check("upgrade: a sudo prompt is recognised, not filed as a plain failure",
                Updates.needsPassword(sudoFailure))
        c.check("upgrade: an ordinary brew error is not mistaken for a password prompt",
                !Updates.needsPassword("Error: ffmpeg: undefined method `foo' for nil"))
        c.check("upgrade: a success is not a password prompt",
                !Updates.needsPassword("==> Upgrading yt-dlp\n==> Pouring yt-dlp.bottle.tar.gz"))

        // brew writes colour codes whenever it believes it has a terminal; the log pane showed
        // them raw as [32m==> until HOMEBREW_COLOR was swapped for HOMEBREW_NO_COLOR
        c.eq("upgrade: colour codes are stripped from log lines",
             Updates.stripANSI("\u{1B}[32m==>\u{1B}[0m \u{1B}[1mUpgrading zulu@17\u{1B}[0m"),
             "==> Upgrading zulu@17")
        c.eq("upgrade: plain text passes through untouched",
             Updates.stripANSI("==> Pouring yt-dlp.bottle.tar.gz"),
             "==> Pouring yt-dlp.bottle.tar.gz")
        c.eq("upgrade: a lone escape at the end does not run off the string",
             Updates.stripANSI("done\u{1B}"), "done")

        c.check("updates: results are sorted by name",
                f.map { $0.name } == f.map { $0.name }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }
}
