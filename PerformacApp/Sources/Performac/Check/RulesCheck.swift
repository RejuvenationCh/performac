// Check/RulesCheck.swift: ports of v1 test/rules.test.js. Card copy expectations
// are asserted verbatim: the v1 tests are the executable specification.
import Foundation

@MainActor
enum RulesCheck {
    static let DAY: Int64 = 86_400_000
    static let NOW: Int64 = 1_756_000_000_000
    static let H: Int64 = 3_600_000

    static var cacheCfg: Config {
        var c = Config.defaults
        c.cacheRules = CacheRules(amberGb: 5, redGb: 20, staleDays: 21)
        return c
    }
    static var tcfg: Config {
        var c = Config.defaults
        c.export = Export(cpuPct: 150, minMinutes: 10)
        c.thermal = Thermal(minElevatedMinutes: 10)
        return c
    }
    static var dcfg: Config {
        var c = Config.defaults
        c.drive = Drive(cycles24h: 2, cycles7d: 3)
        return c
    }
    static var bcfg: Config {
        var c = Config.defaults
        c.backup = Backup(maxAgeDays: 7, watchPaths: [], checkTimeMachine: true)
        return c
    }
    static var hcfg: Config {
        var c = Config.defaults
        c.hog = Hog(cpuPct: 80, minMinutes: 30, lookbackHours: 24,
                    ignore: ["kernel_task", "WindowServer", "launchd", "mds_stores", "backupd"])
        c.idle = Idle(rssMb: 800, hours: 12)
        return c
    }
    static var scfg: Config {
        var c = Config.defaults
        c.storage = Storage(fitDays: 14, warnWeeksLeft: 8, redWeeksLeft: 3)
        return c
    }
    static var dcfg2: Config {
        var c = Config.defaults
        c.drift = Drift(paths: ["~/Downloads", "~/Desktop"], minAgeDays: 60, minMb: 100, maxItems: 8)
        return c
    }
    static var b16cfg: Config {
        var c = Config.defaults
        c.tier3 = Tier3(browserBloat: true)
        return c
    }

    // proc samples every 30s from T0 for `minutes`, cpu alternating between lo and hi
    static func exportSamples(_ name: String, _ t0: Int64, _ minutes: Int, _ lo: Double, _ hi: Double) -> [ProcSample] {
        var rows: [ProcSample] = []
        var i = 0
        while Int64(i) * 30_000 < Int64(minutes) * 60_000 {
            rows.append(ProcSample(ts: t0 + Int64(i) * 30_000, pid: 1, name: name, cpu: i % 2 == 1 ? hi : lo, rssMb: 500))
            i += 1
        }
        return rows
    }

    static func thermEvent(_ t0: Int64, _ level: Int) -> EventRow {
        EventRow(ts: t0, kind: "thermal", key: "thermlog", detail: String(level))
    }

    static func samples(_ specs: [(Int, Int, Int)]) -> [CacheSample] {
        specs.map { daysAgo, sizeGb, mtimeDaysAgo in
            CacheSample(ts: NOW - Int64(daysAgo) * DAY, cacheId: "premiere-media", path: "/test/Media Cache Files",
                        sizeMb: Int64(sizeGb * 1024), newestMtime: NOW - Int64(mtimeDaysAgo) * DAY, fileCount: 100)
        }
    }

    static func driveEvent(_ ts: Int64, _ kind: String, _ vol: String) -> EventRow {
        EventRow(ts: ts, kind: kind, key: vol, detail: "")
    }

    static func pair(_ ts: Int64, _ vol: String = "T7", _ gapMin: Int = 5) -> [EventRow] {
        [driveEvent(ts, "unmount", vol), driveEvent(ts + Int64(gapMin) * 60_000, "mount", vol)]
    }

    static func sleepGap(_ start: Int64, _ end: Int64) -> EventRow {
        EventRow(ts: end, kind: "sleep_gap", key: "sleep_gap", detail: String(start))
    }

    static func hogSamples(_ name: String, _ minutes: Int, _ lo: Double, _ hi: Double, _ t0: Int64 = NOW) -> [ProcSample] {
        var rows: [ProcSample] = []
        var i = 0
        while Int64(i) * 30_000 <= Int64(minutes) * 60_000 {
            rows.append(ProcSample(ts: t0 + Int64(i) * 30_000, pid: 1, name: name, cpu: i % 2 == 1 ? hi : lo, rssMb: 500))
            i += 1
        }
        return rows
    }

    static func diskSamples(_ vol: String, _ nDays: Int, _ f: (Int) -> Double) -> [DiskSample] {
        var rows: [DiskSample] = []
        for d in 0 ..< nDays {
            rows.append(DiskSample(ts: NOW - Int64(nDays - 1 - d) * DAY, volume: vol, freeGb: f(d), totalGb: 1000))
        }
        return rows
    }

    static func driftEntry(_ folder: String, _ name: String, _ sizeMb: Double, _ ageDays: Int) -> Rules.DriftEntry {
        Rules.DriftEntry(path: "\(folder)/\(name)", folder: folder, sizeMb: sizeMb,
                         mtime: NOW - Int64(ageDays) * DAY, ageDays: nil)
    }

    static func run(_ c: CheckSuite) async {
        // ---- cacheGrowth ----
        do {
            let fs = Rules.cacheGrowth(samples([(30, 32, 30), (7, 36, 30), (0, 38, 24)]), cacheCfg, NOW)
            c.check("cache: one red finding", fs.count == 1)
            let f = fs[0]
            c.eq("cache: severity", f.severity, "red")
            // size_mb is MiB; 32/36/38 "GB" in the fixture are really GiB, so the correct decimal
            // text (mbText, matching Fmt.bytes) reads a bit larger: 38 GiB is 40.8 GB, not 38.0.
            c.eq("cache: exact headline", f.headline, "Premiere's media cache is 40.8 GB and hasn't been written to in 24 days")
            c.check("cache: growth why", f.why.contains("grew 2.1 GB in the last 7 days"), f.why)
            c.eq("cache: linkKind", f.linkKind, "reveal")
            c.eq("cache: linkTarget", f.linkTarget, "/test/Media Cache Files")
            c.check("cache: in-app route", f.detail.contains("Settings → Media Cache"), f.detail)
        }
        c.check("cache: 2 GB fresh → none", Rules.cacheGrowth(samples([(0, 2, 0)]), cacheCfg, NOW).isEmpty)
        do {
            let fs = Rules.cacheGrowth(samples([(0, 6, 1)]), cacheCfg, NOW)
            c.check("cache: 6 GB yesterday → info", fs.count == 1 && fs[0].severity == "info")
            c.check("cache: in active use", fs.count == 1 && fs[0].why.contains("in active use: leave it"), fs.first?.why ?? "")
        }
        do {
            let fs = Rules.cacheGrowth(samples([(0, 6, 15)]), cacheCfg, NOW)
            c.check("cache: 15 d under line → info", fs.count == 1 && fs[0].severity == "info")
            c.check("cache: honest about age", fs.count == 1 && fs[0].why.contains("still under your 21-day staleness line"), fs.first?.why ?? "")
            c.check("cache: not in active use", fs.count == 1 && !fs[0].why.contains("in active use"), fs.first?.why ?? "")
        }
        do {
            let fs = Rules.cacheGrowth(samples([(0, 8, 30)]), cacheCfg, NOW)
            c.check("cache: 8 GB 30 d → amber", fs.count == 1 && fs[0].severity == "amber")
            c.check("cache: 30 days in headline", fs.count == 1 && fs[0].headline.contains("hasn't been written to in 30 days"), fs.first?.headline ?? "")
        }
        do {
            let fs = Rules.cacheGrowth(samples([(0, 38, 24)]), cacheCfg, NOW)
            c.check("cache: no growth sample → age-only why", fs.count == 1 && !fs[0].why.contains("grew"), fs.first?.why ?? "")
        }
        do {
            var gcfg = Config.defaults
            gcfg.cacheRules = CacheRules(amberGb: 2, redGb: 20, staleDays: 21)
            let rows = [CacheSample(ts: NOW, cacheId: "gen-npm", path: "/x/npm", sizeMb: 3072, newestMtime: NOW - 30 * DAY, fileCount: 10)]
            let fs = Rules.cacheGrowth(rows, gcfg, NOW)
            c.check("cache: gen-npm amber + purge link", fs.count == 1 && fs[0].severity == "amber" && fs[0].linkKind == "open_purge")
            c.check("cache: gen-npm headline", fs.count == 1 && fs[0].headline.contains("npm's cache") && fs[0].headline.contains("30 days"), fs.first?.headline ?? "")
        }
        do {
            var gcfg = Config.defaults
            gcfg.cacheRules = CacheRules(amberGb: 2, redGb: 20, staleDays: 21)
            let rows = [CacheSample(ts: NOW, cacheId: "gen-zen", path: "/x/zen", sizeMb: 3072, newestMtime: NOW - 40 * DAY, fileCount: 10)]
            let fs = Rules.cacheGrowth(rows, gcfg, NOW)
            c.check("cache: gen-zen reveal link", fs.count == 1 && fs[0].linkKind == "reveal")
            c.check("cache: gen-zen rebuild note", fs.count == 1 && fs[0].detail.lowercased().contains("rebuild"), fs.first?.detail ?? "")
        }

        // ---- thermalDuringExport ----
        // Rebuilt on real degrees. The old version read pmset pressure levels and never
        // fired once on this machine, because pmset has never recorded a warning level.
        do {
            let T0: Int64 = NOW - 40 * 60_000
            func exportRun(_ name: String, _ minutes: Int) -> [ProcSample] {
                stride(from: 0, to: minutes * 60_000, by: 30_000).map {
                    ProcSample(ts: T0 + Int64($0), pid: 1, name: name, cpu: 320, rssMb: 900)
                }
            }
            func temps(_ minutes: Int, _ c: Double) -> [TempSample] {
                stride(from: 0, to: minutes * 60_000, by: 30_000).map {
                    TempSample(ts: T0 + Int64($0), celsius: c)
                }
            }
            let cfgT = Config.defaults

            // hot for long enough → amber, and the headline speaks in degrees
            let hot = Rules.thermalDuringExport(exportRun("Adobe Media Encoder 2026", 30),
                                                temps(30, 91), cfgT, NOW, nil)
            c.check("thermal: a hot export is reported", hot.count == 1)
            c.check("thermal: headline carries the peak in degrees",
                    hot.first?.headline.contains("91°C") == true, hot.first?.headline ?? "")
            c.check("thermal: 30 hot minutes is amber", hot.first?.severity == "amber")

            // a cool export still reports, and says nothing was throttled
            let cool = Rules.thermalDuringExport(exportRun("Adobe Media Encoder 2026", 30),
                                                 temps(30, 62), cfgT, NOW, nil)
            c.check("thermal: a cool export says so", cool.first?.severity == "info")
            c.check("thermal: cool wording mentions no throttling",
                    cool.first?.why.contains("nothing was throttled") == true)

            // too short to count as an export
            c.check("thermal: a brief burst is not an export",
                    Rules.thermalDuringExport(exportRun("Resolve", 3), temps(3, 95), cfgT, NOW, nil).isEmpty)
            // no readings at all → silence, never a guess
            c.check("thermal: no temperature data means no card",
                    Rules.thermalDuringExport(exportRun("Resolve", 30), [], cfgT, NOW, nil).isEmpty)
            // battery is a different explanation and must be named as one
            let onBatt = Rules.thermalDuringExport(exportRun("Resolve", 30), temps(30, 92), cfgT, NOW,
                                                   EventRow(ts: NOW, kind: "power", key: "Battery Power", detail: ""))
            c.check("thermal: battery is explained, not blamed on cooling",
                    onBatt.first?.detail.contains("battery") == true)

            // the reported bug: two unrelated bursts days apart must not fuse into one export.
            // Old code took first/last across a process's whole retained history, so a 30-min
            // burst four days ago and a 15-min burst just now became one ~5775-minute "export"
            // peaking at whichever burst happened to run hotter.
            let oldT0 = NOW - 4 * DAY
            let recentT0 = NOW - 20 * 60_000
            let oldBurst = exportRun("Adobe Premiere Pro 2026", 30).map {
                ProcSample(ts: oldT0 + ($0.ts - T0), pid: $0.pid, name: $0.name, cpu: $0.cpu, rssMb: $0.rssMb)
            }
            let recentBurst = exportRun("Adobe Premiere Pro 2026", 15).map {
                ProcSample(ts: recentT0 + ($0.ts - T0), pid: $0.pid, name: $0.name, cpu: $0.cpu, rssMb: $0.rssMb)
            }
            let oldTemps = temps(30, 95).map { TempSample(ts: oldT0 + ($0.ts - T0), celsius: $0.celsius) }
            let recentTemps = temps(15, 60).map { TempSample(ts: recentT0 + ($0.ts - T0), celsius: $0.celsius) }
            let split = Rules.thermalDuringExport(oldBurst + recentBurst, oldTemps + recentTemps, cfgT, NOW, nil)
            c.check("thermal: two bursts days apart → one card", split.count == 1)
            c.check("thermal: peak is the recent window's, not the old hot burst's",
                    split.first?.headline.contains("60°C") == true, split.first?.headline ?? "")
            c.check("thermal: not the 4-day span reported as the export length",
                    split.first?.headline.contains("95°C") != true, split.first?.headline ?? "")
            c.check("thermal: recent window is cool → info, not amber off the old burst",
                    split.first?.severity == "info", split.first?.severity ?? "")
        }

        // ---- exportWindows: the shared window splitter isExportWindow and thermalDuringExport both use ----
        do {
            let cfgT = Config.defaults
            func s(_ ts: Int64, _ cpu: Double) -> ProcSample { ProcSample(ts: ts, pid: 1, name: "Resolve", cpu: cpu, rssMb: 500) }
            let apart = [s(0, 300), s(60_000, 300), s(5 * 60_000, 300), s(6 * 60_000, 300)]
            c.eq("exportWindows: gap over 2 min stays two windows", Rules.exportWindows(apart, cfgT).count, 2)
            let close = [s(0, 300), s(60_000, 300), s(150_000, 300), s(210_000, 300)]
            c.eq("exportWindows: gap under 2 min merges into one window", Rules.exportWindows(close, cfgT).count, 1)
        }

        // ---- driveInstability ----
        do {
            let events = [driveEvent(NOW - 26 * H, "mount", "Macintosh HD")]   // boot noise → ignored
                + pair(NOW - 20 * H) + pair(NOW - 6 * H) + pair(NOW - 1 * H)
            let fs = Rules.driveInstability(events, dcfg, NOW)
            c.check("drive: 3 cycles → red", fs.count == 1 && fs[0].severity == "red")
            c.eq("drive: exact headline", fs.first?.headline, "T7 disconnected and reconnected 3 times in the last 24 hours")
            c.eq("drive: exact why", fs.first?.why,
                 "A loose cable, failing port, or failing drive shows up as surprise unmount cycles. Check the connection before you trust it with anything you cannot replace")
            c.check("drive: no link", fs.first?.linkKind == nil)
        }
        do {
            let events = pair(NOW - 6 * 86_400_000) + pair(NOW - 3 * 86_400_000)
            c.check("drive: 2 cycles over 7 d → none", Rules.driveInstability(events, dcfg, NOW).isEmpty)
        }
        do {
            c.check("drive: single unmount no remount → none (user ejected)",
                    Rules.driveInstability([driveEvent(NOW - 2 * H, "unmount", "T7")], dcfg, NOW).isEmpty)
        }
        do {
            let events = [driveEvent(NOW - 2 * H, "unmount", "T7"), driveEvent(NOW - 2 * H + 40 * 60_000, "mount", "T7")]
            c.check("drive: 40 min apart → not a cycle", Rules.driveInstability(events, dcfg, NOW).isEmpty)
        }
        do {
            let events = pair(NOW - 6 * 86_400_000) + pair(NOW - 5 * 86_400_000)
                + pair(NOW - 4 * 86_400_000) + pair(NOW - 3 * 86_400_000)
            let fs = Rules.driveInstability(events, dcfg, NOW)
            c.check("drive: 4 cycles → amber", fs.count == 1 && fs[0].severity == "amber")
            c.check("drive: 7-day headline", fs.count == 1 && fs[0].headline.contains("in the last 7 days"), fs.first?.headline ?? "")
        }
        do {
            let gapStarts = [NOW - 20 * H, NOW - 6 * H, NOW - H]
            var events: [EventRow] = []
            for gs in gapStarts {
                events += pair(gs + 1000, "T7", 10)
                events.append(sleepGap(gs, gs + 10 * 60_000 + 30_000))
            }
            c.check("drive: sleep-straddling pairs suppressed", Rules.driveInstability(events, dcfg, NOW).isEmpty)
        }
        do {
            let oldGap = NOW - 24 * H
            let events = [sleepGap(oldGap, oldGap + 600_000)] + pair(NOW - 20 * H) + pair(NOW - 6 * H) + pair(NOW - H)
            let fs = Rules.driveInstability(events, dcfg, NOW)
            c.check("drive: awake pairs after old gap still fire", fs.count == 1 && fs[0].severity == "red")
        }
        do {
            // Real 'External SSD' sequence: second mount had no user action and no recorded
            // unmount: a mount for an already-mounted volume counts as a flap.
            let events = [
                driveEvent(NOW - 300_000, "mount", "External SSD"),
                driveEvent(NOW - 232_000, "mount", "External SSD"),   // the flap
                driveEvent(NOW - 136_000, "unmount", "External SSD"),
                driveEvent(NOW - 129_000, "mount", "External SSD"),   // ordinary paired cycle
            ]
            var cfg = Config.defaults
            cfg.drive = Drive(cycles24h: 1, cycles7d: 3)
            let fs = Rules.driveInstability(events, cfg, NOW)
            c.check("drive: flap counts (2 cycles > 1)", fs.count == 1 && fs[0].headline.contains("2 times"), fs.first?.headline ?? "")
        }
        do {
            let wake = NOW - 100_000
            var cfg = Config.defaults
            cfg.drive = Drive(cycles24h: 0, cycles7d: 0)
            let events = [
                driveEvent(NOW - 400_000, "mount", "T7"),
                sleepGap(NOW - 300_000, wake),
            driveEvent(wake + 5000, "mount", "T7"),   // reappears on wake, normal
            ]
            c.check("drive: wake reappearance not a flap", Rules.driveInstability(events, cfg, NOW).isEmpty)
        }
        do {
            // explicit: a volume's first mount is boot noise, not a cycle
            var cfg = Config.defaults
            cfg.drive = Drive(cycles24h: 0, cycles7d: 0)
            c.check("drive: first mount is boot noise",
                    Rules.driveInstability([driveEvent(NOW - 60_000, "mount", "T7")], cfg, NOW).isEmpty)
        }

        // ---- backupStaleness ----
        do {
            let fs = Rules.backupStaleness(Rules.TmState(configured: false, names: [], backupISO: nil), [], bcfg, NOW)
            c.check("backup: no destination → red", fs.count == 1 && fs[0].severity == "red")
            c.eq("backup: exact headline", fs.first?.headline, "No Time Machine destination is configured on this Mac")
            c.eq("backup: exact why", fs.first?.why,
                 "A Mac that has never been backed up is one drive failure from losing everything on it, and whatever cannot be re-downloaded or re-created is gone for good")
            c.check("backup: no link", fs.first?.linkKind == nil)
            c.check("backup: System Settings detail", fs.count == 1 && fs[0].detail.contains("System Settings"), fs.first?.detail ?? "")
        }
        do {
            let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(NOW - 12 * DAY) / 1000))
            let fs = Rules.backupStaleness(Rules.TmState(configured: true, names: ["T7 Backup"], backupISO: iso), [], bcfg, NOW)
            c.check("backup: 12 d old → red", fs.count == 1 && fs[0].severity == "red")
            c.eq("backup: exact headline", fs.first?.headline, "Your last Time Machine backup is 12 days old")
            c.check("backup: cites destination", fs.count == 1 && fs[0].why.contains("T7 Backup"), fs.first?.why ?? "")
        }
        do {
            let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(NOW - 3 * DAY) / 1000))
            c.check("backup: 3 d old → none",
                    Rules.backupStaleness(Rules.TmState(configured: true, names: ["T7 Backup"], backupISO: iso), [], bcfg, NOW).isEmpty)
        }
        do {
            let fs = Rules.backupStaleness(Rules.TmState(configured: true, names: ["T7 Backup"], backupISO: nil), [], bcfg, NOW)
            c.check("backup: unreadable → info", fs.count == 1 && fs[0].severity == "info")
            c.check("backup: manual check detail", fs.count == 1 && fs[0].detail.contains("tmutil latestbackup"), fs.first?.detail ?? "")
            c.check("backup: does not request FDA", fs.count == 1 && fs[0].detail.contains("does not request"), fs.first?.detail ?? "")
        }
        do {
            let watchStats = [Rules.WatchStat(path: "/Users/you/Movies/Resolve Project Backups",
                                              newestMtime: NOW - 20 * DAY, maxAgeDays: 14)]
            let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(NOW - 3 * DAY) / 1000))
            let fs = Rules.backupStaleness(Rules.TmState(configured: true, names: ["T7 Backup"], backupISO: iso), watchStats, bcfg, NOW)
            c.check("backup: watched path over limit → amber", fs.count == 1 && fs[0].severity == "amber")
            c.check("backup: watch headline", fs.count == 1 && fs[0].headline.contains("Resolve Project Backups") && fs[0].headline.contains("20 days"), fs.first?.headline ?? "")
            c.eq("backup: watch reveal", fs.first?.linkKind, "reveal")
            c.eq("backup: watch target", fs.first?.linkTarget, "/Users/you/Movies/Resolve Project Backups")
        }
        do {
            let watchStats = [Rules.WatchStat(path: "/x", newestMtime: NOW - DAY, maxAgeDays: 14)]
            let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(NOW) / 1000))
            c.check("backup: watched path fresh → none",
                    Rules.backupStaleness(Rules.TmState(configured: true, names: [], backupISO: iso), watchStats, bcfg, NOW).isEmpty)
        }
        do {
            var off = Config.defaults
            off.backup = Backup(maxAgeDays: 7, watchPaths: [], checkTimeMachine: false)
            let watchStats = [Rules.WatchStat(path: "/Users/you/Movies/Resolve Project Backups",
                                              newestMtime: NOW - 20 * DAY, maxAgeDays: 14)]
            let fs = Rules.backupStaleness(Rules.TmState(configured: false, names: [], backupISO: nil), watchStats, off, NOW)
            c.check("backup: TM off → no TM card, watched paths still checked",
                    fs.filter { $0.id.hasPrefix("backup-") }.count == 1)
            c.check("backup: TM off → watched path card", fs.count == 1 && fs[0].headline.contains("Resolve Project Backups"), fs.first?.headline ?? "")
        }

        // ---- dupFindings ----
        do {
            let groups = [
                Rules.DupGroup(hash: String(repeating: "a", count: 64), sizeMb: 300, paths: ["/x/1", "/y/2"]),
                Rules.DupGroup(hash: String(repeating: "b", count: 64), sizeMb: 4301, paths: ["/x/a", "/y/b", "/z/c"]),
                Rules.DupGroup(hash: String(repeating: "c", count: 64), sizeMb: 50, paths: ["/x/i", "/y/j"]),
            ]
            let fs = Rules.dupFindings(groups, Config.defaults)
            c.check("dup: 3 groups", fs.count == 3)
            // sizeMb is MiB; 4301 MiB decimal is 4.5 GB (not the old 4301/1024 = "4.2 GB").
            c.check("dup: sorted by wasted bytes", fs[0].headline.contains("4.5 GB file exists in 3 places"), fs[0].headline)
            c.eq("dup: 3 copies amber", fs[0].severity, "amber")
            c.check("dup: byte-for-byte", fs[0].why.contains("byte-for-byte match (SHA-256)"), fs[0].why)
            c.eq("dup: reveal", fs[0].linkKind, "reveal")
            c.eq("dup: target", fs[0].linkTarget, "/x/a")
            // 300 MiB decimal is 315 MB (not the old bare "300 MB", which treated MiB as MB).
            c.eq("dup: second headline", fs[1].headline, "The same 315 MB file exists in 2 places")
            c.eq("dup: 2 copies info", fs[1].severity, "info")
            c.check("dup: extra paths in detail", fs[0].detail.contains("/z/c"), fs[0].detail)
            c.check("dup: empty → empty", Rules.dupFindings([], Config.defaults).isEmpty)
        }

        // ---- sustainedHogs ----
        do {
            let fs = Rules.sustainedHogs(hogSamples("RobloxPlayer", 35, 88, 96), hcfg, NOW)
            c.check("hog: 35 min → amber", fs.count == 1 && fs[0].severity == "amber")
            c.eq("hog: exact headline", fs.first?.headline, "RobloxPlayer has averaged 92% CPU for 35 minutes")
            c.check("hog: spike wording", fs.count == 1 && fs[0].why.contains("not a momentary spike"), fs.first?.why ?? "")
            c.eq("hog: activity monitor link", fs.first?.linkKind, "open_activity_monitor")
        }
        c.check("hog: 20 min → none", Rules.sustainedHogs(hogSamples("RobloxPlayer", 20, 88, 96), hcfg, NOW).isEmpty)
        c.check("hog: ignore list respected", Rules.sustainedHogs(hogSamples("kernel_task", 40, 90, 90), hcfg, NOW).isEmpty)
        c.check("hog: export-class during export excluded", Rules.sustainedHogs(hogSamples("Adobe Media Encoder 2026", 40, 300, 400), hcfg, NOW).isEmpty)
        do {
            let fs = Rules.sustainedHogs(hogSamples("Resolve", 35, 88, 96), hcfg, NOW)
            c.check("hog: export-class below export.cpuPct still flagged",
                    fs.count == 1 && fs[0].headline.contains("Resolve"), fs.first?.headline ?? "")
        }

        // ---- idleLoaded ----
        do {
            let procs = [ProcSample(ts: NOW - 60_000, pid: 1, name: "Adobe Premiere Pro 2026", cpu: 5, rssMb: 6144)]
            let fronts = [EventRow(ts: NOW - 30 * H, kind: "front_app", key: "Adobe Premiere Pro 2026", detail: "")]
            let fs = Rules.idleLoaded(procs, fronts, hcfg, NOW)
            c.check("idle: 6 GB 12h → info", fs.count == 1 && fs[0].severity == "info")
            c.check("idle: 6.0 GB in headline", fs.count == 1 && fs[0].headline.contains("6.0 GB of RAM"), fs.first?.headline ?? "")
            c.check("idle: since yesterday", fs.count == 1 && fs[0].headline.contains("hasn't been in front since yesterday"), fs.first?.headline ?? "")
            c.check("idle: anti-placebo why", fs.count == 1 && fs[0].why.lowercased().contains("pressure"), fs.first?.why ?? "")
            c.check("idle: no link", fs.first?.linkKind == nil)
        }
        do {
            let procs = [ProcSample(ts: NOW - 60_000, pid: 1, name: "Adobe Premiere Pro 2026", cpu: 5, rssMb: 6144)]
            let fronts = [EventRow(ts: NOW - 2 * H, kind: "front_app", key: "Adobe Premiere Pro 2026", detail: "")]
            c.check("idle: recent front → none", Rules.idleLoaded(procs, fronts, hcfg, NOW).isEmpty)
        }
        c.check("idle: below RSS threshold → none",
                Rules.idleLoaded([ProcSample(ts: NOW - 60_000, pid: 1, name: "Zen", cpu: 5, rssMb: 500)], [], hcfg, NOW).isEmpty)
        c.check("idle: stale samples ignored",
                Rules.idleLoaded([ProcSample(ts: NOW - 3 * H, pid: 1, name: "Zen", cpu: 5, rssMb: 9000)], [], hcfg, NOW).isEmpty)
        do {
            let procs = [ProcSample(ts: NOW - 60_000, pid: 1, name: "Adobe Premiere Pro 2026", cpu: 5, rssMb: 6144)]
            let fronts = [EventRow(ts: NOW - 30 * H, kind: "front_app", key: "Adobe Premiere Pro 2026", detail: "")]
            let fs = Rules.idleLoaded(procs, fronts, hcfg, NOW)
            c.check("idle: since-copy with timestamp", fs.count == 1 && fs[0].headline.contains("hasn't been in front since yesterday"), fs.first?.headline ?? "")
            c.check("idle: no fallback copy", fs.count == 1 && !fs[0].headline.contains("the last 12 hours"), fs.first?.headline ?? "")
        }
        do {
            let procs = [ProcSample(ts: NOW - 60_000, pid: 1, name: "com.apple.Virtualization.VirtualMachine", cpu: 5, rssMb: 950)]
            let fronts = [EventRow(ts: NOW - H, kind: "front_app", key: "Zen", detail: "")]
            c.check("idle: system service never front → none", Rules.idleLoaded(procs, fronts, hcfg, NOW).isEmpty)
        }
        do {
            let procs = [
                ProcSample(ts: NOW - 60_000, pid: 1, name: "plugin-container", cpu: 5, rssMb: 900),
                ProcSample(ts: NOW - 60_000, pid: 2, name: "Zen Helper (Renderer)", cpu: 5, rssMb: 1200),
                ProcSample(ts: NOW - 60_000, pid: 3, name: "Zen", cpu: 5, rssMb: 2500),
            ]
            let fronts = [EventRow(ts: NOW - 30 * H, kind: "front_app", key: "Zen", detail: "")]
            let fs = Rules.idleLoaded(procs, fronts, hcfg, NOW)
            c.check("idle: only exact front name admits", fs.count == 1 && fs[0].headline.contains("Zen"), "got \(fs.count)")
        }

        // ---- storageTrend ----
        do {
            let rows = diskSamples("Macintosh HD", 15) { 80 - Double($0) * (18.0 / 14.0) }
            let fs = Rules.storageTrend(rows, scfg, NOW)
            c.check("storage: 9 GB/week → amber", fs.count == 1 && fs[0].severity == "amber")
            c.eq("storage: exact headline", fs.first?.headline,
                 "Macintosh HD is losing ~9 GB a week: full in about 7 weeks at this rate")
            c.check("storage: cites window + free", fs.count == 1 && fs[0].why.contains("14") && fs[0].why.contains("62"), fs.first?.why ?? "")
        }
        do {
            let rows = diskSamples("Macintosh HD", 15) { 100 - Double($0) * (60.0 / 14.0) }
            c.check("storage: under redWeeksLeft → red", Rules.storageTrend(rows, scfg, NOW).first?.severity == "red")
        }
        c.check("storage: growing → none", Rules.storageTrend(diskSamples("Macintosh HD", 15) { 50 + Double($0) }, scfg, NOW).isEmpty)
        c.check("storage: flat → none", Rules.storageTrend(diskSamples("Macintosh HD", 15) { _ in 62 }, scfg, NOW).isEmpty)
        c.check("storage: < 4 days history → none",
                Rules.storageTrend(diskSamples("Macintosh HD", 4) { 80 - Double($0) * 3 }, scfg, NOW).isEmpty)
        c.check("storage: slow drain under warnWeeksLeft → none",
                Rules.storageTrend(diskSamples("Macintosh HD", 15) { 500 - Double($0) * 0.1 }, scfg, NOW).isEmpty)

        // ---- drift ----
        do {
            let DL = "/Users/testuser/Downloads"
            let entries = [
                driftEntry(DL, "Setup.dmg", 5325, 180),
                driftEntry(DL, "Export_v1.mp4", 3072, 190),
                driftEntry(DL, "Footage.mov", 2048, 200),
                driftEntry(DL, "Installer.pkg", 1024, 150),
                driftEntry(DL, "fresh.zip", 2048, 2),
                driftEntry(DL, "tiny.txt", 1, 300),
            ]
            let fs = Rules.drift(entries, dcfg2, NOW)
            c.check("drift: one card", fs.count == 1 && fs[0].severity == "info")
            // 11469 MiB decimal is 12.0 GB (not the old 11469/1024 = "11.2 GB").
            c.eq("drift: exact headline", fs.first?.headline, "4 old installers and exports are sitting in Downloads (12.0 GB)")
            c.check("drift: per-item why", fs.count == 1 && fs[0].why.contains("Setup.dmg") && fs[0].why.contains("untouched 6 months"), fs.first?.why ?? "")
            c.eq("drift: reveal", fs.first?.linkKind, "reveal")
            c.eq("drift: target", fs.first?.linkTarget, DL)
        }
        do {
            let DL = "/Users/testuser/Downloads"
            let DT = "/Users/testuser/Desktop"
            let entries = [driftEntry(DL, "a.dmg", 500, 100), driftEntry(DT, "b.zip", 600, 100)]
            c.check("drift: one card per folder", Rules.drift(entries, dcfg2, NOW).count == 2)
            c.check("drift: empty → none", Rules.drift([], dcfg2, NOW).isEmpty)
            c.check("drift: fresh → none", Rules.drift([driftEntry(DL, "fresh.zip", 500, 2)], dcfg2, NOW).isEmpty)
        }

        // ---- loginItemsAudit ----
        // These are written to FALSIFY, not confirm. v1's rule passed its own tests while
        // producing 19 false findings live, including Performac's own running backend.
        do {
            let plenty = 30.0
            // an agent launchd is running RIGHT NOW must never be called unused
            c.check("login: running agent never flagged", Rules.loginItemsAudit(
                [], [Rules.LoginAgent(label: "com.chris.performac", program: "node")], [],
                ["com.chris.performac"], plenty, Config.defaults, NOW).isEmpty)
            // label never matches a process name; the resolved program does
            c.check("login: matched by program, not label", Rules.loginItemsAudit(
                [], [Rules.LoginAgent(label: "com.chris.performac", program: "node")], ["node"],
                [], plenty, Config.defaults, NOW).isEmpty)
            // genuinely idle: not running, program never sampled
            let idle = Rules.loginItemsAudit(
                [], [Rules.LoginAgent(label: "com.dead.agent", program: "ghostd")], ["node"],
                [], plenty, Config.defaults, NOW)
            c.check("login: truly unused agent flagged", idle.count == 1)
            c.check("login: headline cites the real window",
                    idle.first?.headline.contains("30 days of samples") == true)
            // a fresh database cannot support the claim
            c.check("login: thin history → silence", Rules.loginItemsAudit(
                ["Ice"], [Rules.LoginAgent(label: "com.dead.agent", program: "ghostd")], [],
                [], 0.4, Config.defaults, NOW).isEmpty)
            // plain login items still work by name
            let fs = Rules.loginItemsAudit(["Ice", "AltTab", "OneDrive"], [], ["AltTab", "OneDrive"],
                                           [], plenty, Config.defaults, NOW)
            c.check("login: unmatched item flagged", fs.count == 1 && fs[0].headline.hasPrefix("Ice"))
            c.check("login: all matched → empty", Rules.loginItemsAudit(
                ["AltTab"], [], ["AltTab"], [], plenty, Config.defaults, NOW).isEmpty)

            // A Login Item has no removable API: the remedy is a deep link to the pane.
            c.eq("login: item gets login_settings link", fs.first?.linkKind, "login_settings")
            c.check("login: item link has no target", fs.first?.linkTarget == nil)

            // A LaunchAgent with a known plist path gets a real, reversible remedy.
            let withPath = Rules.loginItemsAudit(
                [], [Rules.LoginAgent(label: "com.dead.agent", program: "ghostd",
                                      plistPath: "/Users/testuser/Library/LaunchAgents/com.dead.agent.plist")],
                ["node"], [], plenty, Config.defaults, NOW)
            c.eq("login: agent with path gets disable_agent link", withPath.first?.linkKind, "disable_agent")
            c.eq("login: agent link target is the plist path", withPath.first?.linkTarget,
                 "/Users/testuser/Library/LaunchAgents/com.dead.agent.plist")

            // An agent read from an older, pathless setting offers no button rather than one
            // that cannot work.
            c.check("login: agent without a path has no link", idle.first?.linkKind == nil)
        }

        // ---- FindingLink: login_settings / disable_agent ----
        do {
            c.check("link: login_settings constructs", FindingLink(kind: "login_settings", target: nil) == .loginSettings)
            c.check("link: disable_agent constructs with a path",
                    FindingLink(kind: "disable_agent", target: "/a/b.plist") == .disableAgent("/a/b.plist"))
            c.check("link: disable_agent with nil target is nil",
                    FindingLink(kind: "disable_agent", target: nil) == nil)
            c.check("link: disable_agent with empty target is nil",
                    FindingLink(kind: "disable_agent", target: "") == nil)
        }

        // ---- browserBloat ----
        do {
            let rows = [ProcSample(ts: NOW, pid: 1, name: "Zen", cpu: 5, rssMb: 5000)]
            var off = Config.defaults
            off.tier3 = Tier3(browserBloat: false)
            c.check("browser: gated off → none", Rules.browserBloat(rows, off, NOW).isEmpty)
        }
        do {
            var rows: [ProcSample] = []
            var i = 0
            while Int64(i) * 30_000 <= 60 * 60_000 {
                let ts = NOW - 60 * 60_000 + Int64(i) * 30_000
                rows.append(ProcSample(ts: ts, pid: 1, name: "Zen", cpu: 5, rssMb: 3072))
                rows.append(ProcSample(ts: ts, pid: 2, name: "Google Chrome Helper (Renderer)", cpu: 5, rssMb: 2560))
                i += 1
            }
            let fs = Rules.browserBloat(rows, b16cfg, NOW)
            c.check("browser: 5.5 GB sustained → info", fs.count == 1 && fs[0].severity == "info")
            c.check("browser: 5.5 GB + mostly Zen", fs.count == 1 && fs[0].headline.contains("5.5 GB") && fs[0].headline.contains("mostly Zen"), fs.first?.headline ?? "")
            c.check("browser: no link", fs.first?.linkKind == nil)
            c.check("browser: tab detail", fs.count == 1 && fs[0].detail.lowercased().contains("tab"), fs.first?.detail ?? "")
        }
        do {
            let small = [ProcSample(ts: NOW, pid: 1, name: "Zen", cpu: 5, rssMb: 2000)]
            c.check("browser: under threshold → none", Rules.browserBloat(small, b16cfg, NOW).isEmpty)
            var short: [ProcSample] = []
            var i = 0
            while Int64(i) * 30_000 <= 30 * 60_000 {
                short.append(ProcSample(ts: NOW - 30 * 60_000 + Int64(i) * 30_000, pid: 1, name: "Zen", cpu: 5, rssMb: 5000))
                i += 1
            }
            c.check("browser: too short → none", Rules.browserBloat(short, b16cfg, NOW).isEmpty)
        }
    }
}
