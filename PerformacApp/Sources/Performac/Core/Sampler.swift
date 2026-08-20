// Core/Sampler.swift — 30s tick loop + two long-running event streams. Writes
// samples/events; no parsing logic here (that lives in Collectors). Port of v1
// sampler.js: all spawns go through injectable deps so checks never touch real
// binaries. deps.execFile resolves stdout text; deps.statfs resolves fs stats;
// deps.now() returns ms.
import Foundation

struct StatFs: Sendable {
    var bsize: Int64
    var blocks: Int64
    var bavail: Int64
}

/// A spawned stream child: `onLine` receives complete lines; kill() stops it.
protocol StreamChild: AnyObject, Sendable {
    var onLine: (@Sendable (String) -> Void)? { get set }
    var onExit: (@Sendable () -> Void)? { get set }
    func kill()
}

protocol SamplerDeps: Sendable {
    func execFile(_ bin: String, _ args: [String]) async throws -> String
    func spawn(_ bin: String, _ args: [String]) -> StreamChild
    func statfs(_ path: String) async throws -> StatFs
    func listVolumes() -> [String]
    func realpathSync(_ p: String) throws -> String
    func now() -> Int64
}

// live timestamps for /api/health-style queries (module-level, like v1)
nonisolated(unsafe) var lastTickAt: Int64?
nonisolated(unsafe) var lastFindingsAt: Int64?

// run all rules, upsert findings by id, delete ids no longer produced, notify.
// exec is the injected execFile ({stdout} contract) used by maybeNotify.
func refreshFindings(_ db: DB, _ cfg: Config, _ now: Int64,
                     _ exec: (@Sendable (String, [String]) async throws -> String)?) async {
    let powerEvents = rowsToEvents(db.prepare("SELECT * FROM events WHERE kind = 'power' ORDER BY ts").all())
    let lastPower = powerEvents.last

    var findings: [EngineFinding] = []
    findings += Rules.cacheGrowth(rowsToCacheSamples(db.prepare("SELECT * FROM cache_samples").all()), cfg, now)
    findings += Rules.thermalDuringExport(
        rowsToProcSamples(db.prepare("SELECT * FROM proc_samples ORDER BY ts").all()),
        rowsToEvents(db.prepare("SELECT * FROM events WHERE kind = 'thermal' ORDER BY ts").all()),
        cfg, now, lastPower)
    findings += Rules.driveInstability(
        rowsToEvents(db.prepare("SELECT * FROM events WHERE kind IN ('mount','unmount','sleep_gap') ORDER BY ts").all()),
        cfg, now)
    let tmState: Rules.TmState = {
        guard let s = getSetting(db, "tmState")?.objectVal else {
            return Rules.TmState(configured: false, names: [], backupISO: nil)
        }
        return Rules.TmState(
            ts: s["ts"]?.doubleVal.map(Int64.init) ?? 0,
            configured: s["configured"]?.boolVal ?? false,
            names: s["names"]?.arrayVal?.compactMap { $0.stringVal } ?? [],
            backupISO: s["backupISO"]?.stringVal)
    }()
    findings += Rules.backupStaleness(tmState, watchStats(db), cfg, now)
    findings += Rules.sustainedHogs(
        rowsToProcSamples(db.prepare("SELECT * FROM proc_samples WHERE ts > ?")
            .all([.int(now - Int64(cfg.hog.lookbackHours) * 3_600_000)])), cfg, now)
    findings += Rules.idleLoaded(
        rowsToProcSamples(db.prepare("SELECT * FROM proc_samples WHERE ts > ?")
            .all([.int(now - 3_600_000)])),
        rowsToEvents(db.prepare("SELECT * FROM events WHERE kind = 'front_app'").all()),
        cfg, now)
    findings += Rules.storageTrend(rowsToDiskSamples(db.prepare("SELECT * FROM disk_samples").all()), cfg, now)
    findings += Rules.drift(driftEntries(db), cfg, now)
    findings += Rules.loginItemsAudit(
        getSetting(db, "loginItems")?.objectVal?["items"]?.arrayVal?.compactMap { $0.stringVal } ?? [],
        getSetting(db, "loginAgents")?.objectVal?["agents"]?.arrayVal?.compactMap { $0.stringVal } ?? [],
        db.prepare("SELECT DISTINCT name FROM proc_samples WHERE ts > ?")
            .all([.int(now - 30 * 86_400_000)]).compactMap { $0["name"]?.stringVal },
        cfg, now)
    findings += Rules.batteryTrend(
        rowsToEvents(db.prepare("SELECT * FROM events WHERE kind = 'battery' ORDER BY ts").all()).compactMap { e in
            guard let data = e.detail.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return Rules.BatterySample(
                ts: e.ts,
                cycleCount: Int64(obj["cycleCount"] as? Double ?? 0),
                healthPct: obj["healthPct"] as? Double ?? 0)
        },
        cfg, now, lastPower)
    findings += Rules.browserBloat(
        rowsToProcSamples(db.prepare("SELECT * FROM proc_samples WHERE ts > ?")
            .all([.int(now - 24 * 3_600_000)])), cfg, now)

    let eperm = getSetting(db, "driftEperm")?.arrayVal?.compactMap { $0.stringVal } ?? []
    if !eperm.isEmpty {
        findings.append(EngineFinding(
            id: "perm-drift", kind: "perm", severity: "info",
            headline: "macOS blocked Performac from checking some folders",
            why: "Performac could not read \(eperm.joined(separator: ", ")) — grant Files & Folders access in System Settings → Privacy & Security, then restart Performac.",
            detail: "", linkKind: nil, linkTarget: nil))
    }
    if let sb = getSetting(db, "premiere-sidebyside"), sb.stringVal == "1" {
        findings.append(EngineFinding(
            id: "cache-premiere-sidebyside", kind: "cache", severity: "info",
            headline: "Premiere keeps its media cache next to your media",
            why: "Side-by-side caching is on in Premiere's prefs, so the cache grows wherever your footage lives.",
            detail: "Size and clear it from Premiere: Settings → Media Cache.",
            linkKind: nil, linkTarget: nil))
    }

    let upsert = db.prepare("""
        INSERT INTO findings(id, kind, severity, headline, why, detail, link_kind, link_target, first_seen, updated, last_notified)
        VALUES(?,?,?,?,?,?,?,?,?,?,NULL)
        ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, severity=excluded.severity, headline=excluded.headline,
          why=excluded.why, detail=excluded.detail, link_kind=excluded.link_kind, link_target=excluded.link_target,
          updated=excluded.updated
        """)
    for f in findings {
        upsert.run([.text(f.id), .text(f.kind), .text(f.severity), .text(f.headline), .text(f.why),
                    .text(f.detail), .text(f.linkKind ?? ""), .text(f.linkTarget ?? ""), .int(now), .int(now)])
    }
    if !findings.isEmpty {
        let marks = findings.map { _ in "?" }.joined(separator: ",")
        db.prepare("DELETE FROM findings WHERE id NOT IN (\(marks))")
            .run(findings.map { .text($0.id) })
    } else {
        db.prepare("DELETE FROM findings").run()
    }
    if let exec {
        for f in findings {
            _ = await maybeNotify(db, f, cfg, now, exec)
        }
    }
    lastFindingsAt = now
}

// row mapping helpers (v1's rows are plain dicts; these mirror them 1:1)
func rowsToProcSamples(_ rows: [DBRow]) -> [ProcSample] {
    rows.map { ProcSample(ts: $0["ts"]?.intVal ?? 0, pid: $0["pid"]?.intVal ?? 0,
                          name: $0["name"]?.stringVal ?? "", cpu: $0["cpu"]?.realVal ?? 0,
                          rssMb: $0["rss_mb"]?.intVal ?? 0) }
}
func rowsToDiskSamples(_ rows: [DBRow]) -> [DiskSample] {
    rows.map { DiskSample(ts: $0["ts"]?.intVal ?? 0, volume: $0["volume"]?.stringVal ?? "",
                          freeGb: $0["free_gb"]?.realVal ?? 0, totalGb: $0["total_gb"]?.realVal ?? 0) }
}
func rowsToCacheSamples(_ rows: [DBRow]) -> [CacheSample] {
    rows.map { CacheSample(ts: $0["ts"]?.intVal ?? 0, cacheId: $0["cache_id"]?.stringVal ?? "",
                           path: $0["path"]?.stringVal ?? "", sizeMb: $0["size_mb"]?.intVal ?? 0,
                           newestMtime: $0["newest_mtime"].map { $0.isNull ? nil : $0.intVal } ?? nil,
                           fileCount: Int($0["file_count"]?.intVal ?? 0)) }
}
func rowsToEvents(_ rows: [DBRow]) -> [EventRow] {
    rows.map { EventRow(ts: $0["ts"]?.intVal ?? 0, kind: $0["kind"]?.stringVal ?? "",
                        key: $0["key"]?.stringVal ?? "", detail: $0["detail"]?.stringVal ?? "") }
}
func watchStats(_ db: DB) -> [Rules.WatchStat] {
    (getSetting(db, "watchStats")?.arrayVal ?? []).compactMap { w in
        guard let o = w.objectVal, let path = o["path"]?.stringVal else { return nil }
        return Rules.WatchStat(path: path, newestMtime: o["newestMtime"]?.doubleVal.map(Int64.init),
                               maxAgeDays: Int(o["maxAgeDays"]?.doubleVal ?? 0))
    }
}
func driftEntries(_ db: DB) -> [Rules.DriftEntry] {
    (getSetting(db, "driftEntries")?.arrayVal ?? []).compactMap { e in
        guard let o = e.objectVal, let path = o["path"]?.stringVal, let folder = o["folder"]?.stringVal else { return nil }
        return Rules.DriftEntry(path: path, folder: folder,
                                sizeMb: o["sizeMb"]?.doubleVal ?? 0,
                                mtime: Int64(o["mtime"]?.doubleVal ?? 0), ageDays: nil)
    }
}

let GB: Double = 1_073_741_824

final class Sampler: @unchecked Sendable {
    let db: DB
    let cfg: Config
    let deps: any SamplerDeps

    private var stopped = false
    private var lastFront: String?
    private var lastCpuLimit: Int64?
    private var lastPower: String?
    private var lastTickTs: Int64?
    private var lastVolumes: Set<String>
    private var streams: [StreamChild] = []
    private var probeTasks: [Task<Void, Never>] = []

    // external-only: macOS mounts internal APFS system volumes (Recovery/Update/VM/…)
    // constantly and the feature is about external drives. Verdict cached per volume
    // name — one diskutil info call per name per session, never one per event.
    private var verdictCache: [String: Bool] = [:]      // successful probes only
    private var inflight: [String: Task<Bool?, Never>] = [:]

    init(db: DB, cfg: Config, deps: any SamplerDeps) {
        self.db = db
        self.cfg = cfg
        self.deps = deps
        self.lastVolumes = Set(deps.listVolumes())   // seeded: the first tick is not a spurious diff
        // the two long-running event streams (v1's startSampler bottom)
        startStream("diskutil", ["activity"], { [weak self] line in self?.handleDiskutilLine(line) })
        startStream("pmset", ["-g", "thermlog"], { [weak self] line in self?.handleThermlogLine(line) })
    }

    private func addEvent(_ kind: String, _ key: String, _ detail: String, _ ts: Int64? = nil) {
        db.prepare("INSERT INTO events(ts, kind, key, detail) VALUES(?,?,?,?)")
            .run([.int(ts ?? deps.now()), .text(kind), .text(key), .text(detail)])
    }

    /// external-only filter. The entry is set while the probe is in flight so concurrent
    /// events share one call, then dropped again if it failed. Caching a failure would
    /// write the volume off for the life of the process — and a drive with a loose
    /// connector is the likeliest to be slow to enumerate, i.e. exactly the drive we
    /// must not go blind to.
    private func isExternal(_ name: String) async -> Bool {
        if let v = verdictCache[name] { return v }
        let task: Task<Bool?, Never>
        if let t = inflight[name] {
            task = t
        } else {
            task = Task { [deps] in
                do {
                    let stdout = try await deps.execFile("diskutil", ["info", "-plist", "/Volumes/\(name)"])
                    guard let info = parseDiskutilInfo(stdout) else { return nil }   // failed probe
                    return !info.internal || info.ejectable
                } catch {
                    return nil   // failed probe
                }
            }
            inflight[name] = task
            probeTasks.append(Task { _ = await task.value })
            // cache definite verdicts only (external AND internal). Failed probes — throw or
            // nil parse — are dropped so a reappearing drive is re-probed: a drive with a
            // loose connector is the likeliest to fail, i.e. exactly the drive we must not
            // go blind to.
            Task { [weak self] in
                let result = await task.value
                guard let self else { return }
                self.inflight.removeValue(forKey: name)
                if let result { self.verdictCache[name] = result }
            }
        }
        return await task.value ?? false
    }

    // a reconcile event is skipped if the stream already reported it. The window must
    // cover the tick offset — a stream line lands up to one tick before the next
    // reconcile, so 5 s missed every stream-then-tick pair in real time.
    private var DEDUPE_MS: Int64 { Int64(cfg.tickSec * 2) * 1000 }
    private func recentEvent(_ kind: String, _ key: String) -> Bool {
        db.prepare("SELECT 1 FROM events WHERE kind = ? AND key = ? AND ts > ?")
            .get([.text(kind), .text(key), .int(deps.now() - DEDUPE_MS)]) != nil
    }

    // implicit sleep detection — no pmset log parsing: if the wall clock jumped ≥ 3 ticks
    // between samples, the machine slept. detail = pre-sleep tick ms, ts = the wake tick.
    private var GAP_MS: Int64 { 3 * Int64(cfg.tickSec) * 1000 }

    func tick() async {
        let t = deps.now()
        if let lastTickTs, t - lastTickTs >= GAP_MS {
            addEvent("sleep_gap", "sleep_gap", String(lastTickTs))
        }
        if let psText = try? await deps.execFile("ps", ["-Aceo", "pid,pcpu,rss,comm", "-r"]) {
            let rows = parsePs(psText).sorted { $0.cpu > $1.cpu }
            let insertProc = db.prepare("INSERT INTO proc_samples(ts, pid, name, cpu, rss_mb) VALUES(?,?,?,?,?)")
            for (i, r) in rows.enumerated() {
                let kept = (i < cfg.procKeepTop || r.rssMb >= Int64(cfg.procMinRssMb))
                    && (r.cpu >= cfg.procMinCpu || r.rssMb >= Int64(cfg.procMinRssMb))
                if kept { insertProc.run([.int(t), .int(r.pid), .text(r.name), .real(r.cpu), .int(r.rssMb)]) }
            }
        }

        if let frontText = try? await deps.execFile("lsappinfo", ["front"]) {
            // real `lsappinfo info -only name` needs the ASN: prefix — a bare ASN returns
            // nothing, which silently recorded zero front_app events since day one.
            // ASN shape is ASN:0x<hex>-0x<hex> — both halves carry the 0x prefix.
            var frontName: String?
            if let asn = frontText.firstMatch(of: /ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+/) {
                if let infoText = try? await deps.execFile("lsappinfo", ["info", "-only", "name", String(asn.0)]) {
                    frontName = parseFrontAppName(infoText)
                }
            }
            if let frontName, frontName != lastFront { addEvent("front_app", frontName, "") }
            lastFront = frontName
        }

        if let thermText = try? await deps.execFile("pmset", ["-g", "therm"]) {
            let therm = parseTherm(thermText)
            if let limit = therm.cpuSpeedLimit, limit != lastCpuLimit {
                addEvent("thermal", "cpu_limit", String(limit))
            }
            if let limit = therm.cpuSpeedLimit { lastCpuLimit = limit }
        }

        // power source as context for thermal/battery rules — event only when it changes
        if let battText = try? await deps.execFile("pmset", ["-g", "batt", "-o"]) {
            let power = parsePower(battText)
            if let power, power != lastPower { addEvent("power", power, "") }
            if let power { lastPower = power }
        }

        // settle stream-verdict probes before the reconcile reads them
        for task in probeTasks { _ = await task.value }
        probeTasks.removeAll()

        let vols = Set(deps.listVolumes())
        for v in vols {
            if lastVolumes.contains(v) || recentEvent("mount", v) { continue }
            if await isExternal(v) { addEvent("mount", v, "") }
        }
        for v in lastVolumes {
            if vols.contains(v) || recentEvent("unmount", v) { continue }
            if await isExternal(v) { addEvent("unmount", v, "") }
        }
        lastVolumes = vols

        lastTickTs = t
        lastTickAt = t
        await refreshFindings(db, loadConfig(db), t, { @Sendable [deps] bin, args in try await deps.execFile(bin, args) })
    }

    func diskTick() async {
        let t = deps.now()
        var vols: [(String, String)] = [("Macintosh HD", "/")]
        for v in deps.listVolumes() {
            let p = "/Volumes/\(v)"
            do {
                if try deps.realpathSync(p) != "/" { vols.append((v, p)) }
            } catch { /* not mounted */ }
        }
        let insertDisk = db.prepare("INSERT INTO disk_samples(ts, volume, free_gb, total_gb) VALUES(?,?,?,?)")
        for (name, p) in vols {
            if let st = try? await deps.statfs(p) {
                insertDisk.run([.int(t), .text(name),
                                .real(Double(st.bavail * st.bsize) / GB),
                                .real(Double(st.blocks * st.bsize) / GB)])
            }
        }
        await refreshFindings(db, loadConfig(db), t, { @Sendable [deps] bin, args in try await deps.execFile(bin, args) })
    }

    // MARK: streams

    /// Port of startStream: spawn, feed complete lines to the handler, respawn on exit
    /// with the same 60s backoff v1 uses.
    func startStream(_ bin: String, _ args: [String], _ onLine: @escaping @Sendable (String) -> Void) {
        spawnChild(bin, args, onLine)
    }

    private func spawnChild(_ bin: String, _ args: [String], _ onLine: @escaping @Sendable (String) -> Void) {
        if stopped { return }
        let child = deps.spawn(bin, args)
        child.onLine = { line in onLine(line) }
        child.onExit = { [weak self] in
            guard let self, !self.stopped else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard let self, !self.stopped else { return }
                self.spawnChild(bin, args, onLine)
            }
        }
        streams.append(child)
    }

    /// diskutil activity stream handler — ported exactly (async verdict + dedupe + line ts)
    func handleDiskutilLine(_ line: String) {
        guard let p = parseDiskutilActivity(line) else { return }
        let kind = p.kind == "appeared" ? "mount" : "unmount"
        let probe = Task { [weak self] in
            guard let self else { return }
            let ext = await self.isExternal(p.volume)
            // intra-stream dedupe: the initial dump can emit the same volume twice (volume + snapshot)
            if !ext || self.recentEvent(kind, p.volume) { return }
            self.addEvent(kind, p.volume, "", p.ts)   // line's own Time= stamp, not the insert time
        }
        probeTasks.append(probe)
    }

    func handleThermlogLine(_ line: String) {
        if let p = parseThermlogLine(line) {
            addEvent("thermal", "thermlog", String(p))
        }
    }

    func stop() {
        stopped = true
        for c in streams { c.kill() }
    }
}

// MARK: hourly / daily ticks (ported from sampler.js)

func cacheTick(_ db: DB, _ cfg: Config, _ deps: any SamplerDeps) async {
    let t = deps.now()
    let home = NSHomeDirectory()

    var lrcats: [String]
    let cached = getSetting(db, "lrcatCache")?.objectVal
    if let cached, t - Int64(cached["ts"]?.doubleVal ?? 0) < 86_400_000 {
        lrcats = cached["paths"]?.arrayVal?.compactMap { $0.stringVal } ?? []
    } else {
        do {
            let stdout = try await deps.execFile("mdfind", ["kMDItemFSName == \"*.lrcat\""])
            lrcats = stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            setSetting(db, "lrcatCache", JSONValue.from(["ts": t, "paths": lrcats]))
        } catch {
            lrcats = cached?["paths"]?.arrayVal?.compactMap { $0.stringVal } ?? []
        }
    }

    func readText(_ parts: String...) -> String {
        (try? String(contentsOfFile: ([home] + parts).joined(separator: "/"), encoding: .utf8)) ?? ""
    }
    let resolveCfg = readText("Library/Preferences/Blackmagic Design/DaVinci Resolve/config.dat")
    let prefs = readPremierePrefs(home)

    // discover big per-bundle cache dirs in ~/Library/Caches (fixed registry entries skipped here)
    let fixedCacheNames: Set<String> = ["com.apple.dt.Xcode", "Google", "BraveSoftware", "zen"]
    var cacheDirs: [CacheTargetsInputs.DiscoveredCacheDir] = []
    if let names = try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/Caches") {
        for name in names {
            if name.hasPrefix(".") || fixedCacheNames.contains(name) { continue }
            let p = home + "/Library/Caches/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            let m = measure(p)
            // ponytail: 500 MB discovery line is plan-literal; calibrate if cards get noisy
            if m.sizeMb > 500 {
                cacheDirs.append(.init(name: name, sizeMb: Int64(m.sizeMb.rounded()),
                                       newestMtime: m.newestMtime, fileCount: m.fileCount))
            }
        }
    }

    let targets = cacheTargets(cfg, inputs: CacheTargetsInputs(home: home, resolveCfg: resolveCfg, prefs: prefs, lrcatPaths: lrcats, cacheDirs: cacheDirs))
    let sideBySide = targets.contains { $0.id == "premiere-media" && $0.note == "side-by-side" }
    if sideBySide { setSetting(db, "premiere-sidebyside", JSONValue.string("1")) }
    else { db.prepare("DELETE FROM settings WHERE key = ?").run([.text("premiere-sidebyside")]) }

    let ins = db.prepare("INSERT INTO cache_samples(ts, cache_id, path, size_mb, newest_mtime, file_count) VALUES(?,?,?,?,?,?)")
    for tg in targets {
        if tg.note == "side-by-side" { continue }   // say so on the card instead of measuring
        if tg.measurement == nil && !FileManager.default.fileExists(atPath: tg.path) { continue }   // optional/absent → skip silently
        let m = tg.measurement ?? measure(tg.path)
        ins.run([.int(t), .text(tg.id), .text(tg.path), .int(Int64(m.sizeMb.rounded())),
                 m.newestMtime.map { .int($0) } ?? .null, .int(Int64(m.fileCount))])
    }
    await refreshFindings(db, loadConfig(db), t, { bin, args in try await deps.execFile(bin, args) })
}

func readPremierePrefs(_ home: String) -> String {
    let base = home + "/Documents/Adobe/Premiere Pro"
    guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base) else { return "" }
    for v in versions {
        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: base + "/" + v) else { continue }
        for prof in profiles where prof.hasPrefix("Profile-") {
            if let text = try? String(contentsOfFile: base + "/" + v + "/" + prof + "/Adobe Premiere Pro Prefs", encoding: .utf8) {
                return text
            }
        }
    }
    return ""
}

func batteryTick(_ db: DB, _ cfg: Config, _ deps: any SamplerDeps) async {
    if !cfg.tier3.battery { return }
    let t = deps.now()
    if let stdout = try? await deps.execFile("ioreg", ["-rn", "AppleSmartBattery"]),
       let b = parseBattery(stdout) {
        let detail = try! JSONSerialization.data(withJSONObject: ["cycleCount": Double(b.cycleCount), "healthPct": b.healthPct])
        db.prepare("INSERT INTO events(ts, kind, key, detail) VALUES(?,?,?,?)")
            .run([.int(t), .text("battery"), .text("battery"), .text(String(data: detail, encoding: .utf8)!)])
    }
    await refreshFindings(db, loadConfig(db), t, { bin, args in try await deps.execFile(bin, args) })
}

func driftTick(_ db: DB, _ cfg: Config, _ deps: any SamplerDeps) async {
    let t = deps.now()
    let home = NSHomeDirectory()
    var entries: [[String: Any]] = []
    var eperm: [String] = []
    for p in cfg.drift.paths {
        let dir = p.hasPrefix("~/") ? home + String(p.dropFirst(2)) : p
        guard let tops = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
            eperm.append(dir)
            continue
        }
        for top in tops {
            let topVals = try? top.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let topIsDir = topVals?.isDirectory ?? false
            if !topIsDir {
                if let st = topVals, let size = st.fileSize {
                    entries.append(["path": top.path, "folder": dir, "sizeMb": Double(size) / 1_048_576,
                                    "mtime": (st.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000])
                }
            } else {
                guard let inner = try? FileManager.default.contentsOfDirectory(at: top, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
                    eperm.append(top.path)
                    continue
                }
                for f in inner {
                    let fVals = try? f.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    guard fVals?.isDirectory == false, let size = fVals?.fileSize else { continue }
                    entries.append(["path": f.path, "folder": dir, "sizeMb": Double(size) / 1_048_576,
                                    "mtime": (fVals?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000])
                }
            }
        }
    }
    setSetting(db, "driftEntries", JSONValue.from(entries))
    setSetting(db, "driftEperm", JSONValue.from(eperm))
    await refreshFindings(db, loadConfig(db), t, { bin, args in try await deps.execFile(bin, args) })
}

func backupTick(_ db: DB, _ cfg: Config, _ deps: any SamplerDeps) async {
    let t = deps.now()
    var tmState: [String: Any] = ["ts": Double(t), "configured": false, "names": [], "backupISO": NSNull()]
    do {
        let stdout = try await deps.execFile("tmutil", ["destinationinfo"])
        let d = parseTmDestinations(stdout)
        tmState["configured"] = d.configured
        tmState["names"] = d.names
        if d.configured {
            do {
                let out = try await deps.execFile("tmutil", ["latestbackup", "-t"])
                tmState["backupISO"] = parseTmLatest(out)?.backupISO ?? NSNull()
            } catch {
                tmState["backupISO"] = NSNull()   // error text → history unreadable
            }
        }
    } catch {
        // tmutil unavailable → configured:false (the machine's true state today)
    }
    setSetting(db, "tmState", JSONValue.from(tmState))

    var stats: [[String: Any]] = []
    for w in cfg.backup.watchPaths {
        let p = w.path.hasPrefix("~/") ? NSHomeDirectory() + String(w.path.dropFirst(2)) : w.path
        let m = measure(p)
        stats.append(["path": p, "newestMtime": m.newestMtime ?? NSNull(), "maxAgeDays": Double(w.maxAgeDays)])
    }
    setSetting(db, "watchStats", JSONValue.from(stats))
    await refreshFindings(db, loadConfig(db), t, { bin, args in try await deps.execFile(bin, args) })
}

// Monday 09:00–10:00 local, once per week (settings.lastDigestNotify): one native ping.
func mondayDigestCheck(_ db: DB, _ cfg: Config, _ now: Int64, _ execFile: @Sendable (String, [String]) async throws -> String) async {
    if !cfg.weeklyDigestNotify || cfg.notifyEnabled == false { return }
    let d = Date(timeIntervalSince1970: Double(now) / 1000)
    let cal = Calendar.current
    if cal.component(.weekday, from: d) != 2 { return }   // 2 = Monday
    if cal.component(.hour, from: d) < 9 { return }
    let monday9 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: d)!
    let monday9Ms = Int64(monday9.timeIntervalSince1970 * 1000)
    if now - monday9Ms > 3_600_000 { return }
    if Int64(getSetting(db, "lastDigestNotify")?.doubleVal ?? 0) >= monday9Ms { return }
    let n = db.prepare("SELECT COUNT(*) n FROM findings WHERE severity != 'info'").get()?["n"]?.intVal ?? 0
    _ = try? await execFile("osascript", ["-e",
        "display notification \"Your weekly Mac digest is ready — \(n) thing\(n == 1 ? "" : "s") worth doing\" with title \"Performac\""])
    setSetting(db, "lastDigestNotify", JSONValue.number(Double(now)))
}
