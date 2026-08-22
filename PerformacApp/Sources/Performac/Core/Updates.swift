// Updates.swift — outdated command-line tools and apps.
//
// Homebrew answers this from metadata it already has on disk: `brew outdated --verbose`
// returns in about half a second and touches no network. That matters — it means the check
// can be offered without turning the app into something that phones home.
//
// The app does NOT run upgrades. It trashes files because the Trash is an undo; a package
// upgrade has no undo, and bumping ffmpeg under a video editor mid-project is exactly the
// kind of "help" nobody asked for. So this names what is behind and hands over the command.
import Foundation

struct OutdatedItem: Identifiable, Sendable {
    var id: String { name + kind.rawValue }
    enum Kind: String, Sendable { case formula, cask }
    var name: String
    var installed: String
    var available: String
    var kind: Kind
    var upgradeCommand: String {
        kind == .cask ? "brew upgrade --cask \(name)" : "brew upgrade \(name)"
    }
}

enum Updates {
    /// Formula lines read `name (1.2.3) < 1.3.0`; a package installed several times lists
    /// every version, so the newest installed one is the one worth comparing against.
    /// Cask lines use `!=` instead of `<` because casks are not always ordered versions.
    static func parse(_ text: String, kind: OutdatedItem.Kind) -> [OutdatedItem] {
        var out: [OutdatedItem] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")") else { continue }
            let name = s[s.startIndex..<open].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let installedList = String(s[s.index(after: open)..<close])
            let installed = installedList.split(separator: ",").last
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? installedList
            let rest = s[s.index(after: close)...]
            guard let sep = rest.range(of: "<") ?? rest.range(of: "!=") else { continue }
            let available = rest[sep.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !available.isEmpty else { continue }
            out.append(OutdatedItem(name: name, installed: installed,
                                    available: available, kind: kind))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static var brewPath: String? {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// How old Homebrew's package list is. The results are only as current as this, and
    /// saying so is the difference between a fact and a guess.
    static func metadataAge() -> TimeInterval? {
        guard let brew = brewPath else { return nil }
        let repo = (brew as NSString).deletingLastPathComponent
        let head = (repo as NSString).deletingLastPathComponent + "/.git/FETCH_HEAD"
        guard let d = try? FileManager.default.attributesOfItem(atPath: head)[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(d)
    }

    static func run(_ args: [String]) async -> String {
        guard let brew = brewPath else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        // brew needs a sane environment when launched from a GUI app
        p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                         "HOME": NSHomeDirectory()]
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func outdated() async -> [OutdatedItem] {
        async let formulae = run(["outdated", "--formula", "--verbose"])
        async let casks = run(["outdated", "--cask", "--verbose", "--greedy"])
        return await parse(formulae, kind: .formula) + parse(casks, kind: .cask)
    }
}
