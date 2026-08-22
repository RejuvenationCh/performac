// Brew.swift — what Homebrew has installed, read from disk without running Homebrew.
//
// Everything here comes from files brew already wrote: Cellar/<name>/<version>/
// INSTALL_RECEIPT.json carries whether you asked for a package or it was dragged in as a
// dependency, when it landed, and what it needs at runtime. Inverting those lists gives the
// reverse dependencies without `brew uses --installed`, which shells out per package.
//
// The Caskroom matters for a different reason. A cask puts the real bundle in /Applications
// and keeps a symlink back to it under Caskroom/<token>/<version>/. Trashing only the bundle
// leaves that record behind, and brew goes on reporting the app as installed — `brew list
// --cask` is nothing but a listing of that directory (verified by creating an empty one and
// watching it appear). So the record has to go with the app.
import Foundation

struct BrewFormula: Sendable {
    var name: String
    var version: String
    var path: String
    var bytes: Int64 = 0
    /// False means nothing asked for this directly — it came in under something else.
    var onRequest: Bool
    var installedAt: Date?
    /// Installed formulae that would break if this one went away.
    var dependents: [String] = []
}

struct BrewCask: Sendable {
    var token: String
    var version: String
    /// The Caskroom record. Trashed alongside the bundle, or brew still thinks it is here.
    var recordPath: String
    /// Where the bundle actually lives, resolved through the Caskroom symlink.
    var appPath: String?
    /// A cask that ships more than an app symlink (a pkg, a daemon) is not ours to unpick.
    var hasExtraPayload: Bool
}

enum Brew {
    static var prefix: String? {
        for p in ["/opt/homebrew", "/usr/local"]
        where FileManager.default.fileExists(atPath: p + "/Cellar") { return p }
        return nil
    }

    /// Newest-looking version directory. Homebrew keeps old kegs around after an upgrade
    /// until `brew cleanup`, and the last one sorted is the one in use.
    private static func versions(in dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Names, versions and dependency wiring. No directory walking, so this is instant —
    /// sizes come separately.
    static func formulae() -> [BrewFormula] {
        guard let cellar = prefix.map({ $0 + "/Cellar" }) else { return [] }
        let fm = FileManager.default
        var out: [BrewFormula] = []
        var dependents: [String: Set<String>] = [:]

        for name in (try? fm.contentsOfDirectory(atPath: cellar)) ?? [] where !name.hasPrefix(".") {
            let kegs = versions(in: cellar + "/" + name)
            guard let version = kegs.last else { continue }
            let receipt = cellar + "/" + name + "/" + version + "/INSTALL_RECEIPT.json"
            var onRequest = true, installedAt: Date? = nil
            if let data = fm.contents(atPath: receipt),
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Absent flags mean an old receipt; treat it as requested rather than hiding it.
                onRequest = (j["installed_on_request"] as? Bool) ?? true
                if let t = j["time"] as? Double { installedAt = Date(timeIntervalSince1970: t) }
                for d in (j["runtime_dependencies"] as? [[String: Any]]) ?? [] {
                    // full_name is tap-qualified for third-party taps; the leaf is the keg name
                    guard let full = d["full_name"] as? String else { continue }
                    dependents[full.split(separator: "/").last.map(String.init) ?? full, default: []]
                        .insert(name)
                }
            }
            out.append(BrewFormula(name: name, version: version,
                                   path: cellar + "/" + name,
                                   onRequest: onRequest, installedAt: installedAt))
        }
        for i in out.indices { out[i].dependents = (dependents[out[i].name] ?? []).sorted() }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Keyed by the bundle path each cask owns, so an app row can find its own record.
    static func casksByAppPath() -> [String: BrewCask] {
        guard let room = prefix.map({ $0 + "/Caskroom" }) else { return [:] }
        let fm = FileManager.default
        var out: [String: BrewCask] = [:]
        for token in (try? fm.contentsOfDirectory(atPath: room)) ?? [] where !token.hasPrefix(".") {
            let record = room + "/" + token
            guard let version = versions(in: record).last else { continue }
            let dir = record + "/" + version
            let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            var appPath: String?
            for e in entries where e.hasSuffix(".app") {
                // the entry is a symlink into /Applications; resolve it rather than guess
                appPath = (try? fm.destinationOfSymbolicLink(atPath: dir + "/" + e)) ?? (dir + "/" + e)
            }
            // metadata files brew always writes are not payload; anything else is
            let noise: Set<String> = [".metadata", "DistributionSummary.plist",
                                      "ExportOptions.plist", "Packaging.log"]
            let extra = entries.contains { !$0.hasSuffix(".app") && !noise.contains($0) }
            guard let appPath else { continue }
            out[appPath] = BrewCask(token: token, version: version, recordPath: record,
                                    appPath: appPath, hasExtraPayload: extra)
        }
        return out
    }
}
