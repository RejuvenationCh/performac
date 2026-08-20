// Check/SamplerCheck.swift — ports of v1 test/sampler.test.js. Everything through
// injected deps; checks never touch real binaries.
import Foundation

/// Mutable capture box: Swift exclusivity traps when a closure reads a `var` local
/// that outlives its stack frame (the sampler calls these closures from any executor).
final class MutBox<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}

final class FakeStream: StreamChild, @unchecked Sendable {
    var onLine: (@Sendable (String) -> Void)?
    let bin: String
    let args: [String]
    init(bin: String, args: [String]) { self.bin = bin; self.args = args }
    func emit(_ line: String) { onLine?(line) }
    func kill() {}
}

final class FakeDeps: SamplerDeps, @unchecked Sendable {
    var ps: String
    var volumes: () -> [String]
    var diskutilInfo: ([String]) -> String
    var nowFn: () -> Int64
    var power: () -> String?
    private(set) var calls: [[String]] = []
    private(set) var streams: [FakeStream] = []
    let statfsResult: StatFs = StatFs(bsize: 4096, blocks: 1_000_000, bavail: 500_000)

    init(ps: String, volumes: @escaping @Sendable () -> [String], diskutilInfo: @escaping @Sendable ([String]) -> String,
         now: @escaping @Sendable () -> Int64, power: @escaping @Sendable () -> String? = { nil }) {
        self.ps = ps
        self.volumes = volumes
        self.diskutilInfo = diskutilInfo
        self.nowFn = now
        self.power = power
    }

    func execFile(_ bin: String, _ args: [String]) async throws -> String {
        calls.append([bin] + args)
        switch bin {
        case "ps": return ps
        case "lsappinfo":
            if args.first == "front" { return "ASN:0x0-0x6d06d:\n" }
            return "\"LSDisplayName\"=\"Zen\""
        case "pmset":
            if args.first == "-g" && args.dropFirst().first == "batt" { return power() ?? "" }
            return "Note: No CPU power status has been recorded"
        case "diskutil":
            if args.first == "info" { return diskutilInfo(args) }
            throw NSError(domain: "fake", code: 1)
        default:
            throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected execFile \(bin)"])
        }
    }

    func spawn(_ bin: String, _ args: [String]) -> StreamChild {
        let c = FakeStream(bin: bin, args: args)
        streams.append(c)
        return c
    }

    func statfs(_ path: String) async throws -> StatFs { statfsResult }
    func listVolumes() -> [String] { volumes() }
    func realpathSync(_ p: String) throws -> String { p }
    func now() -> Int64 { nowFn() }
}

/// Fixtures must be nonisolated: the fakes' @Sendable closures capture them and run
/// off the main actor.
enum SamplerFixtures {
    static let PS = """
      PID  %CPU    RSS COMM
      693  98.2  73072 RobloxPlayer
      172  47.5 171392 WindowServer
    54509  28.1 615328 Claude Helper (Renderer)
    """

    static let DU_APPEAR = "***DiskAppeared ('disk4s2', DAVolumePath = 'file:///Volumes/T7/', DAVolumeKind = 'apfs', DAVolumeName = 'T7') Time=20260820-18:07:36.1551"

    static let PLIST_INTERNAL = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
    	<key>Ejectable</key>
    	<false/>
    	<key>Internal</key>
    	<true/>
    	<key>VolumeName</key>
    	<string>Macintosh HD</string>
    </dict>
    </plist>
    """

    static let PLIST_EXTERNAL = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
    	<key>Ejectable</key>
    	<true/>
    	<key>Internal</key>
    	<false/>
    	<key>VolumeName</key>
    	<string>T7</string>
    </dict>
    </plist>
    """

    static let NOW: Int64 = 1_755_000_000_000

    static func localStamp(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let cal = Calendar.current
        func p(_ n: Int) -> String { String(format: "%02d", n) }
        return "\(cal.component(.year, from: d))\(p(cal.component(.month, from: d)))\(p(cal.component(.day, from: d)))-\(p(cal.component(.hour, from: d))):\(p(cal.component(.minute, from: d))):\(p(cal.component(.second, from: d)))"
    }
}

@MainActor
enum SamplerCheck {
    static func makeDeps(ps: String = SamplerFixtures.PS, volumes: @escaping @Sendable () -> [String] = { [] },
                         diskutilInfo: @escaping @Sendable ([String]) -> String = { _ in SamplerFixtures.PLIST_EXTERNAL },
                         now: @escaping @Sendable () -> Int64 = { SamplerFixtures.NOW },
                         power: @escaping @Sendable () -> String? = { nil }) -> FakeDeps {
        FakeDeps(ps: ps, volumes: volumes, diskutilInfo: diskutilInfo, now: now, power: power)
    }

    static func run(_ c: CheckSuite) async {
        // two ticks: filtered ps rows, single front_app event (unchanged), thermlog → thermal
        do {
            let db = DB(path: ":memory:")
            let deps = makeDeps()
            let s = Sampler(db: db, cfg: Config.defaults, deps: deps)
            await s.tick()

            let procs = db.prepare("SELECT * FROM proc_samples ORDER BY cpu DESC").all()
            c.check("tick: 3 proc rows", procs.count == 3, "got \(procs.count)")
            c.eq("tick: top proc name", procs.first?["name"]?.stringVal, "RobloxPlayer")
            c.eq("tick: proc ts", procs.first?["ts"]?.intVal, SamplerFixtures.NOW)

            await s.tick()   // second tick: front unchanged → still one event
            let fronts = db.prepare("SELECT * FROM events WHERE kind = 'front_app'").all()
            c.check("tick: second identical tick must not re-emit", fronts.count == 1, "got \(fronts.count)")
            c.eq("tick: front key", fronts.first?["key"]?.stringVal, "Zen")
            let infoCall = deps.calls.first { $0.first == "lsappinfo" && $0.dropFirst().first == "info" }
            c.eq("tick: full ASN token passed", infoCall, ["lsappinfo", "info", "-only", "name", "ASN:0x0-0x6d06d"])

            let thermStream = deps.streams.first { $0.bin == "pmset" }!
            thermStream.emit("2026-08-20 13:11:08 +0700 Thermal Warning Level = 1")
            let therm = db.prepare("SELECT * FROM events WHERE kind = 'thermal'").all()
            c.check("tick: thermlog → thermal event", therm.count == 1)
            c.eq("tick: therm key", therm.first?["key"]?.stringVal, "thermlog")
            c.eq("tick: therm detail", therm.first?["detail"]?.stringVal, "1")
            s.stop()
        }

        // ps filter
        do {
            let ps = """
              PID  %CPU    RSS COMM
              111  0.5   1000 TinyHelper
              222  2.0 900000 Sleeper
              333  47.5 171392 WindowServer
            """
            let db = DB(path: ":memory:")
            let s = Sampler(db: db, cfg: Config.defaults, deps: makeDeps(ps: ps))
            await s.tick()
            let names = db.prepare("SELECT name FROM proc_samples ORDER BY name").all().compactMap { $0["name"]?.stringVal }
            c.eq("tick: ps filter", names, ["Sleeper", "WindowServer"])
            s.stop()
        }

        // diskTick
        do {
            let db = DB(path: ":memory:")
            let s = Sampler(db: db, cfg: Config.defaults, deps: makeDeps(volumes: { ["T7"] }))
            await s.diskTick()
            let rows = db.prepare("SELECT * FROM disk_samples ORDER BY volume").all()
            c.check("diskTick: one row per volume", rows.count == 2)
            c.eq("diskTick: volumes", rows.compactMap { $0["volume"]?.stringVal }, ["Macintosh HD", "T7"])
            let expectedGb = 500_000.0 * 4096 / 1_073_741_824
            c.check("diskTick: free_gb math", abs((rows[0]["free_gb"]?.realVal ?? 0) - expectedGb) < 1e-9)
            c.eq("diskTick: ts", rows[0]["ts"]?.intVal, SamplerFixtures.NOW)
            s.stop()
        }

        // volumes reconcile
        do {
            let db = DB(path: ":memory:")
            let vols = MutBox<[String]>([])   // boot state: seeds from whatever is mounted at start
            let s = Sampler(db: db, cfg: Config.defaults, deps: makeDeps(volumes: { vols.value }))
            vols.value = ["T7"]
            await s.tick()
            c.eq("reconcile: mount on appear", db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get()?["n"]?.intVal, 1)
            vols.value = []
            await s.tick()
            c.eq("reconcile: unmount on disappear", db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'unmount'").get()?["n"]?.intVal, 1)
            s.stop()
        }

        // stream line with DAVolumeName <null>
        do {
            let db = DB(path: ":memory:")
            let deps = makeDeps()
            let s = Sampler(db: db, cfg: Config.defaults, deps: deps)
            let duStream = deps.streams.first { $0.bin == "diskutil" }!
            duStream.emit("***DiskAppeared ('disk0', DAVolumePath = '<null>', DAVolumeKind = '<null>', DAVolumeName = '<null>') Time=20260820-18:07:36.1554")
            c.check("stream: <null> line → no row", db.prepare("SELECT COUNT(*) n FROM events").get()?["n"]?.intVal == 0)
            s.stop()
        }

        // internal volumes → zero events
        do {
            let db = DB(path: ":memory:")
            let deps = makeDeps(diskutilInfo: { _ in SamplerFixtures.PLIST_INTERNAL })
            let s = Sampler(db: db, cfg: Config.defaults, deps: deps)
            let duStream = deps.streams.first { $0.bin == "diskutil" }!
            for name in ["Recovery", "Update", "VM", "Preboot", "Macintosh HD"] {
                duStream.emit("***DiskAppeared ('x', DAVolumePath = 'file:///System/Volumes/x/', DAVolumeKind = 'apfs', DAVolumeName = '\(name)') Time=20260820-18:07:36.1551")
            }
            await s.tick()
            c.check("stream: internal volumes → zero events",
                    db.prepare("SELECT COUNT(*) n FROM events WHERE kind IN ('mount','unmount')").get()?["n"]?.intVal == 0)
            s.stop()
        }

        // external volume → one mount; verdict cached (no second diskutil call)
        do {
            let db = DB(path: ":memory:")
            let deps = makeDeps()
            let s = Sampler(db: db, cfg: Config.defaults, deps: deps)
            let duStream = deps.streams.first { $0.bin == "diskutil" }!
            duStream.emit(SamplerFixtures.DU_APPEAR)   // the initial dump can carry the same name twice
            duStream.emit(SamplerFixtures.DU_APPEAR)
            await s.tick()
            c.eq("stream: external → one mount", db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get()?["n"]?.intVal, 1)
            let infoCalls = deps.calls.filter { $0.first == "diskutil" && $0.dropFirst().first == "info" }
            c.check("stream: verdict cached (one probe)", infoCalls.count == 1, "got \(infoCalls.count)")
            s.stop()
        }

        // reconcile: internal volume in set diff → no event
        do {
            let db = DB(path: ":memory:")
            let info: @Sendable ([String]) -> String = { args in
                args.contains { $0.contains("Macintosh HD") } ? SamplerFixtures.PLIST_INTERNAL : SamplerFixtures.PLIST_EXTERNAL
            }
            let vols = MutBox<[String]>([])
            let s = Sampler(db: db, cfg: Config.defaults, deps: makeDeps(volumes: { vols.value }, diskutilInfo: info))
            vols.value = ["Macintosh HD", "T7"]
            await s.tick()
            let mounts = db.prepare("SELECT key FROM events WHERE kind = 'mount'").all().compactMap { $0["key"]?.stringVal }
            c.eq("reconcile: only external volumes pass", mounts, ["T7"])
            s.stop()
        }

        // stream event deduped against reconcile
        do {
            let db = DB(path: ":memory:")
            let vols = MutBox<[String]>([])
            let deps = makeDeps(volumes: { vols.value })
            let s = Sampler(db: db, cfg: Config.defaults, deps: deps)
            let duStream = deps.streams.first { $0.bin == "diskutil" }!
            duStream.emit(SamplerFixtures.DU_APPEAR)
            await s.tick()
            c.eq("dedupe: stream insert", db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get()?["n"]?.intVal, 1)
            vols.value = ["T7"]
            await s.tick()
            c.eq("dedupe: reconcile does not duplicate", db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get()?["n"]?.intVal, 1)
            s.stop()
        }

        // power events only on change
        do {
            let db = DB(path: ":memory:")
            let p = MutBox<String?>("Now drawing from 'AC Power'")
            let s = Sampler(db: db, cfg: Config.defaults, deps: makeDeps(power: { p.value }))
            await s.tick()
            await s.tick()
            p.value = "Now drawing from 'Battery Power'"
            await s.tick()
            let powers = db.prepare("SELECT key FROM events WHERE kind = 'power' ORDER BY ts").all().compactMap { $0["key"]?.stringVal }
            c.eq("power: change-only events", powers, ["AC Power", "Battery Power"])
            c.check("power: findings pipeline ran", (db.prepare("SELECT COUNT(*) n FROM findings").get()?["n"]?.intVal ?? 0) >= 1)
            s.stop()
        }

        // sleep gap detection
        do {
            let db = DB(path: ":memory:")
            let t = MutBox<Int64>(SamplerFixtures.NOW)
            let s = Sampler(db: db, cfg: Config.defaults, deps: makeDeps(now: { t.value }))
            await s.tick()
            c.eq("sleep: no gap on normal tick", db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'sleep_gap'").get()?["n"]?.intVal, 0)
            t.value += 3 * 30_000   // 90 s at tickSec 30 — the machine slept
            await s.tick()
            let gaps = db.prepare("SELECT * FROM events WHERE kind = 'sleep_gap'").all()
            c.check("sleep: one gap event", gaps.count == 1)
            c.eq("sleep: gap key", gaps.first?["key"]?.stringVal, "sleep_gap")
            c.eq("sleep: detail = pre-sleep tick", Int64(gaps.first?["detail"]?.stringVal ?? ""), SamplerFixtures.NOW)
            c.eq("sleep: ts = wake tick", gaps.first?["ts"]?.intVal, SamplerFixtures.NOW + 90_000)
            s.stop()
        }
        do {
            let db = DB(path: ":memory:")
            let t = MutBox<Int64>(SamplerFixtures.NOW)
            let s = Sampler(db: db, cfg: Config.defaults, deps: makeDeps(now: { t.value }))
            await s.tick()
            t.value += 60_000   // 2 ticks — slow tick, not sleep
            await s.tick()
            c.eq("sleep: short gap → none", db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'sleep_gap'").get()?["n"]?.intVal, 0)
            s.stop()
        }

        // dedupe mirrors real timing: stream event, reconcile 30 s later
        do {
            let db = DB(path: ":memory:")
            let t = MutBox<Int64>(SamplerFixtures.NOW)
            let vols = MutBox<[String]>([])
            let deps = makeDeps(volumes: { vols.value }, now: { t.value })
            let s = Sampler(db: db, cfg: Config.defaults, deps: deps)
            let duStream = deps.streams.first { $0.bin == "diskutil" }!
            let line = SamplerFixtures.DU_APPEAR.replacingOccurrences(of: "Time=\\d+-\\d\\d:\\d\\d:\\d\\d", with: "Time=\(SamplerFixtures.localStamp(t.value))", options: .regularExpression)
            duStream.emit(line)
            await s.tick()
            c.eq("real timing: stream insert", db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get()?["n"]?.intVal, 1)
            t.value += 30_000
            vols.value = ["T7"]
            await s.tick()
            c.eq("real timing: 30 s offset deduped", db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get()?["n"]?.intVal, 1)
            s.stop()
        }

        // a failed diskutil probe must not poison the verdict cache
        do {
            let db = DB(path: ":memory:")
            let throwingDeps = ThrowingProbeDeps(ps: SamplerFixtures.PS, volumes: { [] }, now: { SamplerFixtures.NOW }, external: SamplerFixtures.PLIST_EXTERNAL)
            let s = Sampler(db: db, cfg: Config.defaults, deps: throwingDeps)
            let duStream = throwingDeps.streams.first { $0.bin == "diskutil" }!
            duStream.emit(SamplerFixtures.DU_APPEAR)   // probe #1 fails → no event, correctly
            await s.tick()
            c.eq("probe: failed first probe → no mount", db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get()?["n"]?.intVal, 0)
            duStream.emit(SamplerFixtures.DU_APPEAR)   // the same drive reappears — re-probed, not blind forever
            await s.tick()
            c.eq("probe: reappearing drive re-probed and seen", db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get()?["n"]?.intVal, 1)
            s.stop()
        }
    }
}

/// First diskutil probe throws (a flaky drive), later probes succeed — the
/// nine-behaviors rule: a failed probe must never be cached.
final class ThrowingProbeDeps: SamplerDeps, @unchecked Sendable {
    var probeCount = 0
    let ps: String
    let volumes: @Sendable () -> [String]
    let nowFn: @Sendable () -> Int64
    let external: String
    private(set) var streams: [FakeStream] = []
    init(ps: String, volumes: @escaping @Sendable () -> [String], now: @escaping @Sendable () -> Int64, external: String) {
        self.ps = ps; self.volumes = volumes; self.nowFn = now; self.external = external
    }
    func execFile(_ bin: String, _ args: [String]) async throws -> String {
        switch bin {
        case "ps": return ps
        case "lsappinfo":
            if args.first == "front" { return "ASN:0x0-0x6d06d:\n" }
            return "\"LSDisplayName\"=\"Zen\""
        case "pmset": return "Note: No CPU power status has been recorded"
        case "diskutil":
            probeCount += 1
            if probeCount == 1 { throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find disk: /Volumes/T7"]) }
            return external
        default:
            throw NSError(domain: "fake", code: 1)
        }
    }
    func spawn(_ bin: String, _ args: [String]) -> StreamChild {
        let c = FakeStream(bin: bin, args: args)
        streams.append(c)
        return c
    }
    func statfs(_ path: String) async throws -> StatFs { StatFs(bsize: 4096, blocks: 1_000_000, bavail: 500_000) }
    func listVolumes() -> [String] { volumes() }
    func realpathSync(_ p: String) throws -> String { p }
    func now() -> Int64 { nowFn() }
}
