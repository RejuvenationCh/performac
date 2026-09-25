// Core/Rules.swift: pure functions, history rows → Finding[]. Card copy is v1's verbatim.
// Finding = {id, kind, severity:'info'|'amber'|'red', headline, why, detail,
//            linkKind:'reveal'|'open_purge'|'open_activity_monitor'|null, linkTarget}
import Foundation

struct EngineFinding: Equatable, Sendable {
    var id: String
    var kind: String
    var severity: String
    var headline: String
    var why: String
    var detail: String
    var linkKind: String?
    var linkTarget: String?
}

struct ProcSample: Sendable {
    var ts: Int64
    var pid: Int64
    var name: String
    var cpu: Double
    var rssMb: Int64
}

struct DiskSample: Sendable {
    var ts: Int64
    var volume: String
    var freeGb: Double
    var totalGb: Double
}

struct CacheSample: Sendable {
    var ts: Int64
    var cacheId: String
    var path: String
    var sizeMb: Int64
    var newestMtime: Int64?
    var fileCount: Int
}

/// One die-temperature reading. Top level, like ProcSample and EventRow.
struct TempSample: Sendable {
    var ts: Int64
    var celsius: Double
    init(ts: Int64, celsius: Double) { self.ts = ts; self.celsius = celsius }
}

struct EventRow: Sendable {
    var ts: Int64
    var kind: String
    var key: String
    var detail: String
}

enum Rules {
    static let DAY: Int64 = 86_400_000
    static let LR_META: (app: String, media: Bool, clearing: String) =
        ("Lightroom Classic", true, "Lightroom Classic: Catalog Settings → Previews.")

    // generic caches: Purge's Safe/Check First split; dynamic per-bundle dirs default to safe
    static let GEN_META: [String: (app: String, safety: String)] = [
        "gen-xcode": ("Xcode", "safe"),
        "gen-deriveddata": ("Xcode", "safe"),
        "gen-npm": ("npm", "safe"),
        "gen-google": ("Google Chrome", "check-first"),
        "gen-brave": ("Brave", "check-first"),
        "gen-zen": ("Zen", "check-first"),
    ]

    /// Casings that plain title-casing gets wrong, kept small and local rather than a
    /// general-purpose app-name dictionary.
    private static let humanizeTokens: [String: String] = [
        "vscode": "VS Code", "npm": "npm", "ios": "iOS", "macos": "macOS",
    ]
    /// Reverse-DNS vendor components a bundle id leads with, never part of the app's name.
    private static let humanizeVendorPrefixes: Set<String> =
        ["com", "org", "io", "net", "co", "dev", "app", "me", "us"]

    /// "com-microsoft-vscode-shipit" → "Microsoft VS Code". Drops the vendor prefix and
    /// Squirrel's "shipit" updater suffix before title-casing what's left.
    static func humanize(_ slugName: String) -> String {
        var parts = slugName.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        if let first = parts.first, humanizeVendorPrefixes.contains(first.lowercased()) {
            parts.removeFirst()
        }
        if let last = parts.last, last.lowercased() == "shipit" {
            parts.removeLast()
        }
        guard !parts.isEmpty else { return slugName }   // never hand back an empty name
        return parts.map { humanizeTokens[$0.lowercased()] ?? ($0.prefix(1).uppercased() + $0.dropFirst()) }
            .joined(separator: " ")
    }

    static func cacheMeta(_ id: String) -> (app: String, media: Bool, safety: String, clearing: String) {
        if id.hasPrefix("gen-") {
            let known = GEN_META[id]
            let app = known?.app ?? humanize(String(id.dropFirst(4)))
            let safety = known?.safety ?? "safe"
            return (app, false, safety, safety == "check-first"
                ? "Browser caches rebuild themselves and clearing signs you out of nothing." : "")
        }
        if let m = CACHE_META[id] { return (m.app, m.media, "unsafe", m.clearing) }
        if id.hasPrefix("lr-") { return (LR_META.app, LR_META.media, "unsafe", LR_META.clearing) }
        return (id, false, "unsafe", "")
    }

    /// "today" / "yesterday" / "16 days ago". ageText omits "ago" so it can be composed;
    /// this is the form for sentences that end there.
    static func ageTextAgo(_ ageDays: Double?) -> String {
        let t = ageText(ageDays)
        return (t == "today" || t == "yesterday" || t == "a while") ? t : t + " ago"
    }

    static func ageText(_ ageDays: Double?) -> String {
        guard let ageDays else { return "a while" }
        if ageDays < 1 { return "today" }
        if ageDays < 2 { return "yesterday" }
        return "\(Int(ageDays.rounded())) days"
    }

    /// "1 week" / "3 weeks": every place a count sits next to a noun goes through this
    /// instead of repeating `n == 1 ? "" : "s"` (or, worse, forgetting the check).
    static func plural(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    // flag only; never move. entries = [{path, folder, sizeMb, mtime}] from the depth-2 walk
    static func drift(_ entries: [DriftEntry], _ cfg: Config, _ now: Int64) -> [EngineFinding] {
        var byFolder: [String: [DriftEntry]] = [:]
        for e in entries {
            let ageDays = Double(now - e.mtime) / Double(DAY)
            if e.sizeMb < cfg.drift.minMb || ageDays < Double(cfg.drift.minAgeDays) { continue }
            byFolder[e.folder, default: []].append(DriftEntry(path: e.path, folder: e.folder, sizeMb: e.sizeMb, mtime: e.mtime, ageDays: ageDays))
        }
        var out: [EngineFinding] = []
        for (folder, items) in byFolder.sorted(by: { $0.key < $1.key }) {
            let sorted = items.sorted { $0.sizeMb > $1.sizeMb }
            let totalMb = sorted.reduce(0) { $0 + $1.sizeMb }
            let name = folder.split(separator: "/").filter { !$0.isEmpty }.last.map(String.init) ?? folder
            out.append(EngineFinding(
                id: "drift-\(slug(folder))", kind: "drift", severity: "info",
                headline: "\(sorted.count) old installers and exports are sitting in \(name) (\(mbText(totalMb)))",
                why: sorted.prefix(cfg.drift.maxItems)
                    .map { i in
                        let base = i.path.split(separator: "/").last.map(String.init) ?? i.path
                        return "\(base): \(mbText(i.sizeMb)), untouched \(plural(Int((i.ageDays! / 30).rounded()), "month"))"
                    }
                    .joined(separator: " · "),
                detail: "Flagging only. Moving or deleting is yours to decide.",
                linkKind: "reveal", linkTarget: folder))
        }
        return out
    }

    struct DriftEntry: Sendable {
        var path: String
        var folder: String
        var sizeMb: Double
        var mtime: Int64
        var ageDays: Double?
    }

    /// The single size formatter. `size_mb` columns are MiB; this converts to bytes and
    /// formats decimally (thousands, not 1024s) so a figure here agrees with `Fmt.bytes`
    /// (Model/ViewModels.swift) to the decimal place, e.g. a 50164 MiB cache reads "52.6 GB"
    /// in both places, not "49.0 GB" here and "52.6 GB" there. Kept in the engine, not shared
    /// with the UI layer, since Rules.swift must not depend on presentation code.
    private static let sizeLocale = Locale(identifier: "en_US")
    static func mbText(_ mb: Double) -> String {
        let bytes = mb * 1_048_576
        let tb = bytes / 1_000_000_000_000
        if tb >= 1 { return String(format: "%.2f TB", locale: sizeLocale, tb) }
        let gb = bytes / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", locale: sizeLocale, gb) }
        return "\(Int((bytes / 1_000_000).rounded())) MB"
    }
    static func mbText(_ mb: Int64) -> String { mbText(Double(mb)) }

    // cross-ref login items + LaunchAgent labels against proc names seen in the last 30 d
    /// A login item or LaunchAgent that appears to do nothing.
    ///
    /// v1 compared LaunchAgent *labels* ("com.chris.performac") against process *names*
    /// ("node"). Those never match, so every agent was flagged, including Performac's own
    /// backend, which was running at the time. 19 of 24 findings were false. Three fixes:
    ///  1. An agent launchd currently has running is in use. Ground truth beats inference.
    ///  2. Otherwise match the agent's resolved program ("node"), never its label.
    ///  3. Say nothing at all until there is enough history to justify the claim.
    struct LoginAgent: Sendable {
        var label: String
        var program: String?      // basename of ProgramArguments[0] / Program, nil if unreadable
        /// The plist's actual file path, not a guess at `~/Library/LaunchAgents/<label>.plist`
        /// a plist's filename is not guaranteed to match its own Label key. nil for agents
        /// read from an older, pathless setting; a card about one then offers no action.
        var plistPath: String?
        init(label: String, program: String? = nil, plistPath: String? = nil) {
            self.label = label; self.program = program; self.plistPath = plistPath
        }
    }

    /// The Trash holds space until it is emptied, and this app puts things there. Without
    /// this card you clean 18 GB, watch free space not move, and conclude the app is broken.
    ///
    /// Performac deliberately does NOT offer to empty it. The Trash is the undo for every
    /// destructive thing this app can do; emptying it is the one step that must stay the
    /// user's own deliberate act.
    static func trashHolding(_ bytes: Int64, _ items: Int, _ cfg: Config, _ now: Int64) -> [EngineFinding] {
        guard bytes >= cfg.trash.minBytes, items > 0 else { return [] }
        return [EngineFinding(
            id: "trash-holding", kind: "trash", severity: "info",
            headline: "Your Trash is holding \(mbText(Double(bytes) / 1_048_576))",
            why: "Space in the Trash is still used. Emptying it is the only step that actually gives it back.",
            detail: "\(plural(items, "item")). Performac never empties the Trash: it is the undo for everything this app removes, so that stays your call.",
            linkKind: "reveal", linkTarget: NSHomeDirectory() + "/.Trash")]
    }

    /// Folders with no second copy anywhere the app can see.
    ///
    /// Phrased as a fact about specific folders, never as advice about backups. The user has
    /// declined a backup drive twice; repeating that would be nagging. Naming the three
    /// folders that are one failure from gone is information they can act on.
    static func singleCopy(_ statuses: [CopyStatus], _ cfg: Config, _ now: Int64) -> [EngineFinding] {
        let alone = statuses.filter { !$0.hasCopy }
        guard !alone.isEmpty else { return [] }
        let total = alone.reduce(Int64(0)) { $0 + $1.bytes }
        let named = alone.prefix(3).map(\.name).joined(separator: ", ")
        let more = alone.count > 3 ? " and \(alone.count - 3) more" : ""
        return [EngineFinding(
            id: "single-copy", kind: "copies", severity: "amber",
            headline: "\(plural(alone.count, "folder")) exist in only one place (\(mbText(Double(total) / 1_048_576)))",
            why: "\(named)\(more): no copy of these was found on any other drive Performac can see.",
            detail: "This is not a backup check: it only sees drives that are connected. A folder listed here has nothing standing between it and a drive failure.",
            linkKind: nil, linkTarget: nil)]
    }

    static func loginItemsAudit(_ items: [String], _ agents: [LoginAgent], _ procNames: [String],
                                _ runningLabels: Set<String>, _ historyDays: Double,
                                _ cfg: Config, _ now: Int64) -> [EngineFinding] {
        // The headline claims a month of evidence. Without it, the honest output is nothing.
        guard historyDays >= Double(cfg.login.minHistoryDays) else { return [] }
        var out: [EngineFinding] = []

        func seen(_ name: String) -> Bool {
            let n = name.lowercased()
            return procNames.contains { p in
                let q = p.lowercased()
                return n == q || n.hasPrefix(q) || q.hasPrefix(n)
            }
        }
        func make(_ label: String, _ detail: String, linkKind: String?, linkTarget: String?) -> EngineFinding {
            EngineFinding(
                id: "login-\(slug(label))", kind: "login", severity: "info",
                headline: "\(label) launches at login but hasn't run in \(plural(Int(historyDays), "day")) of samples",
                why: "It is not running now and its program has not appeared in any sample: it may be doing nothing.",
                detail: detail,
                linkKind: linkKind, linkTarget: linkTarget)
        }

        // Login Items has no public removal API. Accessibility would be needed to script
        // System Events, so the only honest remedy is a deep link to the settings pane.
        for item in items where !seen(item) {
            out.append(make(item,
                "Short-lived helpers can slip between 30-second ticks.",
                linkKind: "login_settings", linkTarget: nil))
        }
        for agent in agents {
            if runningLabels.contains(agent.label) { continue }   // launchd says it is running
            if let prog = agent.program, seen(prog) { continue }  // its program has been sampled
            if agent.program == nil, seen(agent.label) { continue }
            // A LaunchAgent's plist is the user's own file, so unloading it and trashing the
            // plist is a real, reversible fix, offered only when its real path is known.
            if let path = agent.plistPath, !path.isEmpty {
                out.append(make(agent.label,
                    "Short-lived helpers can slip between 30-second ticks. Disabling it unloads it and moves its plist to the Trash, recoverable from there, and it stops relaunching at login.",
                    linkKind: "disable_agent", linkTarget: path))
            } else {
                out.append(make(agent.label,
                    "Short-lived helpers can slip between 30-second ticks. Review it in ~/Library/LaunchAgents.",
                    linkKind: nil, linkTarget: nil))
            }
        }
        return out
    }

    // tier-3 gated. Sums RSS across browser procs per tick, requires the total ≥ rssGb
    // sustained ≥ minMinutes (same gap rule as hogs).
    static func browserBloat(_ procSamples: [ProcSample], _ cfg: Config, _ now: Int64) -> [EngineFinding] {
        if !cfg.tier3.browserBloat { return [] }
        let b = cfg.browser
        let tickMs = Int64((cfg.tickSec) * 1000)
        struct Tick { var total: Int64 = 0; var byProc: [String: Int64] = [:] }
        var byTick: [Int64: Tick] = [:]
        for s in procSamples {
            guard b.procs.contains(where: { s.name.hasPrefix($0) }) else { continue }
            var t = byTick[s.ts] ?? Tick()
            t.total += s.rssMb
            t.byProc[s.name, default: 0] += s.rssMb
            byTick[s.ts] = t
        }
        let sorted = byTick.sorted { $0.key < $1.key }
        var start: Int64?
        var end: Int64?
        var inWindow: [(Int64, Tick)] = []
        for (ts, t) in sorted {
            if t.total < Int64(b.rssGb * 1024) || (start != nil && ts - end! > 2 * tickMs) {
                start = ts
                inWindow.removeAll()
            }
            if start == nil { start = ts }
            end = ts
            inWindow.append((ts, t))
            if end! - start! >= Int64(b.minMinutes * 60_000) { break }
        }
        guard let end, let start, end - start >= Int64(b.minMinutes * 60_000) else { return [] }
        var totals: [String: Int64] = [:]
        for (_, t) in inWindow {
            for (n, mb) in t.byProc { totals[n, default: 0] += mb }
        }
        let top = totals.sorted { $0.value > $1.value }.first!.key
        let peakGb = Double(inWindow.map { $0.1.total }.max()!) / 1024
        return [EngineFinding(
            id: "browser-bloat", kind: "browser", severity: "info",
            headline: "Your browsers are holding \(String(format: "%.1f", peakGb)) GB of RAM (mostly \(top))",
            why: "Total browser memory stayed above \(b.rssGb) GB for at least \(plural(b.minMinutes, "minute")).",
            detail: "A tab audit usually beats quitting browsers: heavy tabs are the real users. macOS reclaims what it needs under pressure.",
            linkKind: nil, linkTarget: nil)]
    }

    // per-volume least-squares fit over fitDays; weeks-left math from the slope.
    // Requires ≥ 4 days of history: a shorter fit is noise, not a trend.
    static func storageTrend(_ diskSamples: [DiskSample], _ cfg: Config, _ now: Int64) -> [EngineFinding] {
        let since = now - Int64(cfg.storage.fitDays) * DAY
        var byVol: [String: [DiskSample]] = [:]
        for s in diskSamples {
            if s.ts < since { continue }
            byVol[s.volume, default: []].append(s)
        }
        var out: [EngineFinding] = []
        for (vol, rows) in byVol.sorted(by: { $0.key < $1.key }) {
            let sorted = rows.sorted { $0.ts < $1.ts }
            if sorted.count < 2 || now - sorted[0].ts < 4 * DAY { continue }
            let n = Double(sorted.count)
            let meanX = sorted.reduce(0.0) { $0 + Double($1.ts) } / n
            let meanY = sorted.reduce(0.0) { $0 + $1.freeGb } / n
            var num = 0.0
            var den = 0.0
            for s in sorted {
                num += (Double(s.ts) - meanX) * (s.freeGb - meanY)
                den += (Double(s.ts) - meanX) * (Double(s.ts) - meanX)
            }
            let gbPerWeek = (num / den) * 7 * 86_400_000
            // ponytail: -0.5 GB/week "≈ flat" line is plan-literal; calibrate if cards get noisy
            if gbPerWeek >= -0.5 { continue }
            let currentFree = sorted[sorted.count - 1].freeGb
            let weeksLeft = currentFree / -gbPerWeek
            if weeksLeft >= Double(cfg.storage.warnWeeksLeft) { continue }
            let severity = weeksLeft < Double(cfg.storage.redWeeksLeft) ? "red" : "amber"
            out.append(EngineFinding(
                id: "storage-\(slug(vol))", kind: "storage", severity: severity,
                headline: "\(vol) is losing ~\(Int((-gbPerWeek).rounded())) GB a week: full in about \(plural(Int(weeksLeft.rounded()), "week")) at this rate",
                why: "Free space fell from \(String(format: "%.0f", sorted[0].freeGb)) GB to \(String(format: "%.0f", currentFree)) GB over the last \(Int(Double(now - sorted[0].ts) / Double(DAY))) days, with \(String(format: "%.0f", currentFree)) GB free now.",
                detail: "", linkKind: nil, linkTarget: nil))
        }
        return out
    }

    // sustained: window of qualifying ticks ≥ minMinutes with ≥ 80% of expected samples present.
    // Export-class procs are excluded while they look like an export (that's supposed to eat CPU).
    static func sustainedHogs(_ procSamples: [ProcSample], _ cfg: Config, _ now: Int64) -> [EngineFinding] {
        let lookback = now - Int64(cfg.hog.lookbackHours * 3_600_000)
        let tickMs = Int64(cfg.tickSec * 1000)
        var byName: [String: [ProcSample]] = [:]
        for s in procSamples {
            if s.ts < lookback || cfg.hog.ignore.contains(s.name) { continue }
            byName[s.name, default: []].append(s)
        }
        var out: [EngineFinding] = []
        for (name, rows) in byName.sorted(by: { $0.key < $1.key }) {
            let sorted = rows.sorted { $0.ts < $1.ts }
            let isExportClass = cfg.exportProcs.contains { name.hasPrefix($0) }
            if isExportClass && isExportWindow(sorted, cfg) { continue }
            var openStart: Int64?
            var openEnd: Int64?
            var openSum = 0.0
            var openCount = 0
            func closeIfNeeded() {
                guard let s = openStart, let e = openEnd else { return }
                let durMs = e - s
                let expected = Int(floor(Double(durMs) / Double(tickMs))) + 1
                if durMs >= Int64(cfg.hog.minMinutes * 60_000) && Double(openCount) >= 0.8 * Double(expected) {
                    out.append(EngineFinding(
                        id: "hog-\(slug(name))", kind: "hog", severity: "amber",
                        headline: "\(name) has averaged \(Int((openSum / Double(openCount)).rounded()))% CPU for \(plural(Int(Double(durMs) / 60_000), "minute"))",
                        why: "That's sustained load, not a momentary spike. If you're not using it, quit it from Activity Monitor.",
                        detail: "", linkKind: "open_activity_monitor", linkTarget: nil))
                }
                openStart = nil; openEnd = nil; openSum = 0; openCount = 0
            }
            for s in sorted {
                if s.cpu < cfg.hog.cpuPct { continue }
                if openStart == nil {
                    openStart = s.ts; openEnd = s.ts; openSum = s.cpu; openCount = 1
                } else if s.ts - openEnd! <= 2 * tickMs {
                    openEnd = s.ts; openSum += s.cpu; openCount += 1
                } else {
                    closeIfNeeded()
                    openStart = s.ts; openEnd = s.ts; openSum = s.cpu; openCount = 1
                }
            }
            closeIfNeeded()
        }
        return out
    }

    /// Contiguous runs of samples above the CPU threshold, merging gaps under 2 minutes.
    /// The one place that decides where an export starts and ends: `isExportWindow` and
    /// `thermalDuringExport` both go through this rather than each taking a first/last
    /// timestamp across a process's *entire* retained history, which is what turned "Premiere
    /// spiked twice, four days apart" into a reported 5834-minute export.
    static func exportWindows(_ rows: [ProcSample], _ cfg: Config) -> [(start: Int64, end: Int64)] {
        let gapMs: Int64 = 2 * 60_000
        var windows: [(start: Int64, end: Int64)] = []
        var start: Int64?
        var end: Int64?
        for s in rows.sorted(by: { $0.ts < $1.ts }) {
            if s.cpu < cfg.export.cpuPct { continue }
            if let e = end, s.ts - e > gapMs {
                windows.append((start!, e))
                start = nil
            }
            if start == nil { start = s.ts }
            end = s.ts
        }
        if let start, let end { windows.append((start, end)) }
        return windows
    }

    static func isExportWindow(_ rows: [ProcSample], _ cfg: Config) -> Bool {
        exportWindows(rows, cfg).contains { $0.end - $0.start >= Int64(cfg.export.minMinutes * 60_000) }
    }

    // anti-placebo stance: never recommend freeing RAM for its own sake.
    // Positive admission: only a process whose exact name has been front_app ever appears.
    static func idleLoaded(_ procSamples: [ProcSample], _ frontEvents: [EventRow], _ cfg: Config, _ now: Int64) -> [EngineFinding] {
        let fresh = now - 3_600_000
        var latest: [String: ProcSample] = [:]
        for s in procSamples {
            if s.ts < fresh || s.rssMb < Int64(cfg.idle.rssMb) { continue }
            if latest[s.name] == nil || s.ts > latest[s.name]!.ts { latest[s.name] = s }
        }
        let fronts = frontEvents.filter { $0.kind == "front_app" }
        // Positive test, not a denylist: surface only a process whose exact name has appeared
        // as a front_app in recorded history. A real app has been in front at some point; a
        // system service (com.apple.*, plugin-container, * Helper) never has, and a denylist
        // keeps leaking new ones. Trade-off: cards stay quiet until front history accumulates
        // after a fresh install; silent beats wrong.
        let everFront = Set(fronts.map { $0.key })
        var out: [EngineFinding] = []
        for (name, s) in latest.sorted(by: { $0.key < $1.key }) {
            if !everFront.contains(name) { continue }
            if fronts.contains(where: { $0.key == name && now - $0.ts < Int64(cfg.idle.hours) * 3_600_000 }) { continue }
            let last = fronts.filter { $0.key == name }.max { $0.ts < $1.ts }!
            let words = name.split(separator: " ").map(String.init)
            let displayWords = words.filter { Int($0) == nil }.prefix(2)
            let display = displayWords.joined(separator: " ")
            out.append(EngineFinding(
                id: "idle-\(slug(name))", kind: "idle", severity: "info",
                headline: "\(display) is holding \(String(format: "%.1f", Double(s.rssMb) / 1024)) GB of RAM and hasn't been in front since \(sinceText(last.ts, now))",
                why: "macOS reclaims memory from background apps under pressure on its own. Free RAM for its own sake does nothing.",
                detail: "Worth quitting only if things actually feel slow.",
                linkKind: nil, linkTarget: nil))
        }
        return out
    }

    static func sinceText(_ ts: Int64, _ now: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ts) / 1000)
        let days = (now - ts) / DAY
        let cal = Calendar.current
        let h = cal.component(.hour, from: d)
        let m = cal.component(.minute, from: d)
        let hm = String(format: "%02d:%02d", h, m)
        if days < 1 { return "today \(hm)" }
        if days < 2 { return "yesterday \(hm)" }
        return "\(cal.component(.month, from: d))/\(cal.component(.day, from: d)) \(hm)"
    }

    // groups = [{hash, sizeMb, paths:[...]}], deliberately exact-only, no fuzzy matching
    struct DupGroup: Sendable {
        var hash: String
        var sizeMb: Int64
        var paths: [String]
    }

    static func dupFindings(_ groups: [DupGroup], _ cfg: Config) -> [EngineFinding] {
        return groups
            .sorted { $0.sizeMb * Int64($0.paths.count - 1) > $1.sizeMb * Int64($1.paths.count - 1) }
            .map { g in
                let copies = g.paths.count
                let wastedMb = g.sizeMb * Int64(copies - 1)
                // ponytail: 1 GB / 3 copies amber lines are plan-literal, not DEFAULTS knobs
                let severity = wastedMb >= 1024 || copies >= 3 ? "amber" : "info"
                let sizeText = mbText(g.sizeMb)
                return EngineFinding(
                    id: "dup-\(g.hash.prefix(12))", kind: "dup", severity: severity,
                    headline: "The same \(sizeText) file exists in \(copies) places",
                    why: "\(g.paths[0]) and \(g.paths[1]) are an exact byte-for-byte match (SHA-256).",
                    detail: g.paths.count > 2 ? "Also: \(g.paths[2...].joined(separator: ", "))" : "",
                    linkKind: "reveal", linkTarget: g.paths[0])
            }
    }

    // tmState = {configured, names, backupISO|null}; watchStats = [{path, newestMtime, maxAgeDays}]
    struct TmState: Sendable {
        var ts: Int64 = 0
        var configured: Bool = false
        var names: [String] = []
        var backupISO: String?
    }

    struct WatchStat: Sendable {
        var path: String
        var newestMtime: Int64?
        var maxAgeDays: Int
    }

    static func backupStaleness(_ tmState: TmState, _ watchStats: [WatchStat], _ cfg: Config, _ now: Int64) -> [EngineFinding] {
        var out: [EngineFinding] = []
        // Time Machine reporting is opt-out per machine (backup.checkTimeMachine). With no
        // destination and none planned, the red card is noise rather than news. The watched
        // paths below are the honest signal instead, and are unaffected by this flag.
        let tmOn = cfg.backup.checkTimeMachine
        if tmOn && !tmState.configured {
            out.append(EngineFinding(
                id: "backup-no-destination", kind: "backup", severity: "red",
                headline: "No Time Machine destination is configured on this Mac",
                why: "A Mac that has never been backed up is one drive failure from losing everything on it, and whatever cannot be re-downloaded or re-created is gone for good",
                detail: "Set one up in System Settings → General → Time Machine.",
                linkKind: nil, linkTarget: nil))
        } else if tmOn, let iso = tmState.backupISO {
            let parsedTs = (try? Date(iso, strategy: .iso8601)).map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            let ageDays = Double(now - parsedTs) / Double(DAY)
            if ageDays > Double(cfg.backup.maxAgeDays) {
                let dest = tmState.names.first ?? "your backup destination"
                out.append(EngineFinding(
                    id: "backup-stale", kind: "backup", severity: "red",
                    headline: "Your last Time Machine backup is \(plural(Int(ageDays.rounded()), "day")) old",
                    why: "The newest backup on \(dest) is from \(iso.prefix(10)): everything shot since then has no copy anywhere.",
                    detail: "", linkKind: nil, linkTarget: nil))
            }
        } else if tmOn {
            out.append(EngineFinding(
                id: "backup-unreadable", kind: "backup", severity: "info",
                headline: "A Time Machine destination exists, but its backup history is unreadable",
                why: "Performac can see \(tmState.names.first ?? "the destination") but could not read the latest backup timestamp.",
                detail: "If this persists with the drive attached, tmutil latestbackup may need Full Disk Access, which Performac deliberately does not request. Check manually: run 'tmutil latestbackup' in Terminal.",
                linkKind: nil, linkTarget: nil))
        }
        for w in watchStats {
            guard let newestMtime = w.newestMtime else { continue }
            let ageDays = Double(now - newestMtime) / Double(DAY)
            if ageDays > Double(w.maxAgeDays) {
                let name = w.path.split(separator: "/").filter { !$0.isEmpty }.last.map(String.init) ?? w.path
                out.append(EngineFinding(
                    id: "backup-watch-\(slug(w.path))", kind: "backup", severity: "amber",
                    headline: "\(name) hasn't seen a new backup in \(plural(Int(ageDays.rounded()), "day"))",
                    why: "The newest file there is \(plural(Int(ageDays.rounded()), "day")) old and you set a \(w.maxAgeDays)-day limit.",
                    detail: "", linkKind: "reveal", linkTarget: w.path))
            }
        }
        return out
    }

    // a "cycle" = unmount followed by reappearance (mount) within 30 min; user ejects don't count.
    // sleep_gap events (ts = wake tick, detail = pre-sleep tick ms) mark machine sleep: a pair
    // whose window overlaps a gap is the Mac napping, not a failing cable. Awake pairs still fire.
    static func driveInstability(_ events: [EventRow], _ cfg: Config, _ now: Int64) -> [EngineFinding] {
        var gaps: [(start: Int64, end: Int64)] = []
        var byVol: [String: [EventRow]] = [:]
        for e in events {
            if e.kind == "sleep_gap" {
                gaps.append((Int64(e.detail) ?? 0, e.ts))
                continue
            }
            if e.kind != "mount" && e.kind != "unmount" { continue }
            byVol[e.key, default: []].append(e)
        }
        var out: [EngineFinding] = []
        for (vol, list) in byVol.sorted(by: { $0.key < $1.key }) {
            let sorted = list.sorted { $0.ts < $1.ts }
            // Two shapes count as a cycle. The ordinary one is unmount -> mount within 30 min.
            // The other is a mount for a volume already believed mounted: it must have gone away
            // and come back with the disconnect too brief for the stream to report at all. That
            // is the more dangerous shape, fast enough to corrupt a write in progress, so a
            // missing unmount must not make it invisible. A volume's first mount is not a cycle
            // (boot noise), and neither is one reappearing across a sleep/wake gap.
            var cycles: [Int64] = []
            let grace = Int64(cfg.tickSec * 2) * 1000
            var mounted = false
            var openUnmount: Int64?
            for e in sorted {
                if e.kind == "unmount" {
                    openUnmount = e.ts
                    mounted = false
                    continue
                }
                if let openUnmount, e.ts - openUnmount <= 30 * 60_000 {
                    if !gaps.contains(where: { openUnmount < $0.end && e.ts > $0.start }) {
                        cycles.append(openUnmount)
                    }
                } else if mounted {
                    if !gaps.contains(where: { e.ts > $0.start && e.ts <= $0.end + grace }) {
                        cycles.append(e.ts)
                    }
                }
                openUnmount = nil
                mounted = true
            }
            let in24 = cycles.filter { now - $0 <= 24 * 3_600_000 }.count
            let in7 = cycles.filter { now - $0 <= 7 * 86_400_000 }.count
            if in24 > cfg.drive.cycles24h {
                out.append(EngineFinding(
                    id: "drive-\(slug(vol))", kind: "drive", severity: "red",
                    headline: "\(vol) disconnected and reconnected \(in24) times in the last 24 hours",
                    why: "A loose cable, failing port, or failing drive shows up as surprise unmount cycles. Check the connection before you trust it with anything you cannot replace",
                    detail: "", linkKind: nil, linkTarget: nil))
            } else if in7 > cfg.drive.cycles7d {
                out.append(EngineFinding(
                    id: "drive-\(slug(vol))", kind: "drive", severity: "amber",
                    headline: "\(vol) disconnected and reconnected \(in7) times in the last 7 days",
                    why: "Repeated disconnects spread over the week point at a loose cable or a failing port. Worth watching before you rely on the drive.",
                    detail: "", linkKind: nil, linkTarget: nil))
            }
        }
        return out
    }

    // export windows (≥ export.cpuPct sustained ≥ export.minMinutes, gaps < 2 min merged)
    // × elevated intervals from thermlog level events (1/2 opens, 0 closes, open at now stays open).
    /// Thermals tied to a workflow event, in degrees.
    ///
    /// This was the second Tier 1 feature in the original scope doc and it never once fired:
    /// it was built on `pmset -g thermlog`, which has never emitted a warning level on this
    /// machine, so it had zero events to reason about. The die sensors turn out to be
    /// readable unprivileged, so it now works from actual temperature.
    ///
    /// An export is expected to be hot. What is worth telling someone is how hot, for how
    /// long, a number they can compare between exports and act on (a stand, a cleaned fan
    /// intake, a shorter timeline).
    static func thermalDuringExport(_ procSamples: [ProcSample], _ temps: [TempSample],
                                    _ cfg: Config, _ now: Int64, _ power: EventRow?) -> [EngineFinding] {
        guard !temps.isEmpty else { return [] }

        // export windows: an export-class process sustaining real load. Grouped by name here
        // (not pre-filtered by CPU) so exportWindows can see the gaps and split real windows
        // itself, same as isExportWindow.
        var byPrefix: [String: [ProcSample]] = [:]
        for s in procSamples {
            guard let prefix = cfg.exportProcs.first(where: { s.name.hasPrefix($0) }) else { continue }
            byPrefix[prefix, default: []].append(s)
        }

        var out: [EngineFinding] = []
        for (app, samples) in byPrefix {
            let qualifying = exportWindows(samples, cfg)
                .filter { $0.end - $0.start >= Int64(cfg.export.minMinutes * 60_000) }
            // one card per app: the export that actually happened, not a splice of every
            // qualifying burst in retained history, so the most recent one.
            guard let window = qualifying.max(by: { $0.start < $1.start }) else { continue }
            let first = window.start, last = window.end
            let minutes = Double(last - first) / 60_000

            let during = temps.filter { $0.ts >= first && $0.ts <= last }
            guard let peak = during.map(\.celsius).max() else { continue }
            // each reading covers one tick, so counting them is counting time
            let hotCount = during.filter { $0.celsius >= cfg.thermal.hotC }.count
            let hotMinutes = Double(hotCount) * Double(cfg.tickSec) / 60

            let onBattery = power?.key == "Battery Power"
            if hotMinutes >= Double(cfg.thermal.minHotMinutes) {
                out.append(EngineFinding(
                    id: "thermal-\(slug(app))", kind: "thermal",
                    severity: hotMinutes >= 20 ? "amber" : "info",
                    headline: "\(app) ran at \(Int(peak.rounded()))°C during a \(Int(minutes))-minute export",
                    why: "It held above \(Int(cfg.thermal.hotC))°C for \(Int(hotMinutes)) of those minutes, which is where this Mac starts throttling: the export takes longer than the work requires.",
                    detail: onBattery
                        ? "This ran on battery, where macOS limits performance by design. On mains it would run cooler and finish sooner."
                        : "Worth checking the vents are clear and the machine is not sitting on something soft.",
                    linkKind: nil, linkTarget: nil))
            } else {
                out.append(EngineFinding(
                    id: "thermal-\(slug(app))", kind: "thermal", severity: "info",
                    headline: "\(app) peaked at \(Int(peak.rounded()))°C during a \(Int(minutes))-minute export",
                    why: "It stayed under \(Int(cfg.thermal.hotC))°C throughout, so nothing was throttled.",
                    detail: "", linkKind: nil, linkTarget: nil))
            }
        }
        return out
    }

    static func cacheGrowth(_ cacheSamples: [CacheSample], _ cfg: Config, _ now: Int64) -> [EngineFinding] {
        var byId: [String: [CacheSample]] = [:]
        for s in cacheSamples {
            byId[s.cacheId, default: []].append(s)
        }
        var out: [EngineFinding] = []
        for (id, rows) in byId.sorted(by: { $0.key < $1.key }) {
            let sorted = rows.sorted { $0.ts < $1.ts }
            let latest = sorted[sorted.count - 1]
            let m = cacheMeta(id)
            // sizeGb stays in the old (GiB, mislabeled) unit deliberately: it only ever feeds
            // the amberGb/redGb threshold comparisons below, which were calibrated against it.
            // Display text uses mbText, the decimal conversion that agrees with the Clean list.
            let sizeGb = Double(latest.sizeMb) / 1024
            let sizeText = mbText(Double(latest.sizeMb))
            if sizeGb < cfg.cacheRules.amberGb { continue }
            let ageDays: Double? = latest.newestMtime.map { Double(now - $0) / Double(DAY) }
            let stale = ageDays.map { $0 >= Double(cfg.cacheRules.staleDays) } ?? false
            let media = m.media ? "media cache" : "cache"
            let severity: String
            let headline: String
            let why: String
            if !stale {
                severity = "info"
                let fresh = (ageDays ?? 0) < 2
                headline = fresh
                    ? "\(m.app)'s \(media) is \(sizeText) and in active use"
                    : "\(m.app)'s \(media) is \(sizeText)"
                why = fresh
                    ? "Last written \(ageTextAgo(ageDays)); in active use: leave it."
                    : "Last written \(ageTextAgo(ageDays)) and still under your \(cfg.cacheRules.staleDays)-day staleness line: leave it."
            } else {
                severity = sizeGb >= cfg.cacheRules.redGb ? "red" : "amber"
                headline = "\(m.app)'s \(media) is \(sizeText) and hasn't been written to in \(plural(Int(ageDays!.rounded()), "day"))"
                let weekAgo = sorted.filter { $0.ts <= now - 7 * DAY }.last
                if let weekAgo, latest.sizeMb > weekAgo.sizeMb {
                    let grew = mbText(Double(latest.sizeMb - weekAgo.sizeMb))
                    why = "It grew \(grew) in the last 7 days and hasn't been touched in \(plural(Int(ageDays!.rounded()), "day")): stale render data your current work no longer needs."
                } else {
                    why = "It hasn't been touched in \(plural(Int(ageDays!.rounded()), "day")): stale render data your current work no longer needs."
                }
            }
            out.append(EngineFinding(
                id: "cache-\(id)", kind: "cache", severity: severity,
                headline: headline, why: why,
                detail: m.clearing.isEmpty ? "" : "Safest route: clear it from inside the app. \(m.clearing)",
                linkKind: m.safety == "safe" ? "open_purge" : "reveal",
                linkTarget: latest.path))
        }
        return out
    }
}
