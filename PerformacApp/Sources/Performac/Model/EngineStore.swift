// Model/EngineStore.swift — the single observable store. Owns the v2 database and
// publishes what the views need. The sampler runs off the main actor and writes to
// SQLite; after each tick the store refreshes on the main actor by reading the
// findings table — cheap by design, never triggers a scan.
//
// Sample (ViewModels.swift) remains the preview/fallback the views default to when
// this store has nothing yet — a first run with no history renders the quiet state.
import SwiftUI
import Foundation

@MainActor
final class EngineStore: ObservableObject {
    static let shared = EngineStore()

    @Published var live: [Finding] = []
    @Published var digest: [Finding] = []
    @Published var cacheEntries: [CacheEntry] = []
    @Published var dupGroups: [DupGroup] = []
    @Published var dupScanAt: Int64? = nil
    @Published var config: Config = .defaults
    @Published var fdaGranted = false
    @Published var lastTickAt: Int64? = nil

    // disk scan state (DiskView)
    @Published var diskEntries: [SizeEntry] = []
    @Published var scanning = false
    @Published var scanFiles = 0
    @Published var scanBytes: Int64 = 0
    @Published var scanElapsed: TimeInterval = 0
    @Published var scanPath = ""

    let db: DB
    /// Read-only connection used by the browser. See DB.init(readOnly:).
    let readDB: DB
    var sampler: Sampler?
    private var scanTask: Task<Void, Never>?
    private var scanStart: Date?
    /// Display mode for the Disk view. Persisted; defaults to the expandable outline.
    @Published var diskViewMode: DiskViewMode = .outline
    /// Right-hand panel shape. Persisted alongside the list mode.
    @Published var rightPanelMode: RightPanelMode = .treemap
    /// Where the browser currently is. Starts at the scan root; clicking a folder descends.
    @Published var browsePath: String = NSHomeDirectory()
    /// What gets scanned. Never assumed: the user picks home, a mounted volume, or any folder.
    @Published var scanRoot: String = NSHomeDirectory()
    /// When the persisted results were produced. nil = never scanned on this machine.
    @Published var lastScanAt: Int64? = nil
    /// Only meaningful once a scan exists; persisted so it survives relaunch.
    @Published var autoRefreshScan = false

    init(db: DB? = nil) {
        let path = db == nil ? copyV1DatabaseIfNeeded(v1Path: V1_DATABASE_PATH) : nil
        self.db = db ?? DB(path: path!)
        // Separate handle for browsing reads so the UI never waits on the sampler's lock.
        self.readDB = (db == nil && path != nil) ? DB(path: path!, readOnly: true) : self.db
        loadPersistedScan()   // reopening shows the last result, labelled as a snapshot
        loadCoachIntro()
    }

    // MARK: worst finding for the menu bar (red > amber > info; empty → quiet)

    var worst: Finding? {
        live.first { $0.severity == .red }
            ?? live.first { $0.severity == .amber }
            ?? live.first { $0.severity == .info }
    }

    var worstTitle: String {
        guard let worst else { return "" }   // bare glyph, no text
        let s = worst.headline
        return s.count > 30 ? String(s.prefix(30)) + "…" : s
    }

    // MARK: refresh from SQLite (cheap — findings table only)

    func refreshFromDatabase() {
        let rows = readDB.prepare("SELECT id, kind, severity, headline, why, detail, link_kind, link_target, updated FROM findings ORDER BY updated DESC").all()
        var findings: [Finding] = []
        var kinds: [String] = []
        for row in rows {
            let severity = row["severity"]?.stringVal ?? "info"
            let linkKind = row["link_kind"]?.stringVal ?? ""
            let link: String?
            switch linkKind {
            case "reveal": link = "Show in Finder"
            case "open_purge": link = "Open Purge"
            case "open_activity_monitor": link = "Open Activity Monitor"
            default: link = nil
            }
            let headline = row["headline"]?.stringVal ?? ""
            let kind = row["kind"]?.stringVal ?? ""
            // These cards are about one process, and its name opens the headline. Only offer
            // quitting when the process is actually live and passes ProcessControl's refusals.
            var quitTarget: String? = nil
            if kind == "hog" || kind == "idle", let name = Self.leadingProcessName(headline),
               case .success = ProcessControl.target(named: name) {
                quitTarget = name
            }
            findings.append(Finding(
                severity: severity == "red" ? .red : severity == "amber" ? .amber : .info,
                headline: headline,
                why: row["why"]?.stringVal ?? "",
                link: link,
                quitTarget: quitTarget))
            kinds.append(kind)
        }
        // v1's split: live = time-sensitive kinds, digest = everything
        let liveKinds: Set<String> = ["drive", "thermal", "backup"]
        live = zip(findings, kinds).filter { liveKinds.contains($0.1) }.map { $0.0 }
        digest = findings
        refreshCacheEntries()
        refreshDupGroups()
        refreshTrend()
        refreshQuietFacts()
        findingsAt = Date()
        config = loadConfig(readDB)
        fdaGranted = EngineStore.checkFullDiskAccess()
    }

    // MARK: Clean view — latest cache sample per target + v1's meta copy

    private func refreshCacheEntries() {
        var entries: [CacheEntry] = []
        let rows = readDB.prepare("SELECT * FROM cache_samples ORDER BY ts DESC").all()
        var seen = Set<String>()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for row in rows {
            guard let id = row["cache_id"]?.stringVal, !seen.contains(id) else { continue }
            seen.insert(id)
            let meta = Rules.cacheMeta(id)
            let bytes = Int64((row["size_mb"]?.intVal ?? 0)) * 1_000_000
            if bytes <= 0 { continue }
            let mtime = row["newest_mtime"]?.isNull == false ? row["newest_mtime"]?.intVal : nil
            let ageDays = mtime.map { Double(now - $0) / Double(Rules.DAY) }
            let path = row["path"]?.stringVal ?? ""
            // The cleaner's allowlist decides — not the measurement registry. Anything
            // without an explicit policy is shown but cannot be selected or trashed.
            let policy = Allowlist.policy(for: CacheTarget(id: id, label: meta.app, path: path,
                                                           safety: meta.safety))
            entries.append(CacheEntry(
                name: meta.app,
                bytes: bytes,
                age: Rules.ageText(ageDays) + (mtime == nil ? "" : " ago"),
                ageDays: ageDays ?? 0,
                safe: policy.safe,
                why: policy.consequence,
                path: path,
                cacheID: id,
                cleanable: policy.cleanable,
                contentsOnly: policy.contentsOnly))
        }
        cacheEntries = entries
    }

    // MARK: Duplicates view — v1's last scan rows (the rescanner arrives with Clean)

    private func refreshDupGroups() {
        let rows = readDB.prepare("SELECT * FROM dup_groups WHERE scan_ts = (SELECT MAX(scan_ts) FROM dup_groups) ORDER BY size_mb DESC").all()
        dupScanAt = readDB.prepare("SELECT MAX(scan_ts) m FROM dup_groups").get()?["m"]?.intVal
        dupGroups = rows.compactMap { row in
            guard let pathsText = row["paths"]?.stringVal,
                  let data = pathsText.data(using: .utf8),
                  let paths = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { return nil }
            let name = (paths.first as NSString?)?.lastPathComponent ?? "file"
            return DupGroup(bytes: (row["size_mb"]?.intVal ?? 0) * 1_000_000, name: name, paths: paths)
        }
    }

    /// "RobloxPlayer has averaged 99% CPU…" → "RobloxPlayer". Matched against processes we
    /// have actually sampled, so a headline can never be parsed into an arbitrary name.
    static func leadingProcessName(_ headline: String) -> String? {
        guard let cut = headline.range(of: " has ") ?? headline.range(of: " is ") else { return nil }
        let name = String(headline[headline.startIndex..<cut.lowerBound])
        return name.isEmpty ? nil : name
    }

    @Published var quitResult: String? = nil

    /// Stage one: ask the app to quit, so it can prompt to save.
    func requestQuit(_ name: String) {
        switch ProcessControl.target(named: name) {
        case .failure(let r): quitResult = r.rawValue
        case .success(let t):
            quitResult = ProcessControl.quit(t)
                ? "Asked \(t.name) to quit. If it has unsaved work it will prompt you."
                : "\(t.name) did not accept the quit request."
        }
    }

    /// Stage two: explicit escalation. Unsaved work is lost.
    func forceQuit(_ name: String) {
        switch ProcessControl.target(named: name) {
        case .failure(let r): quitResult = r.rawValue
        case .success(let t):
            quitResult = ProcessControl.force(t) ? "Force quit \(t.name)." : "Could not force quit \(t.name)."
        }
    }

    // MARK: duplicate scan — on-demand, cancels when you leave, like the disk scan

    @Published var dupScanning = false
    @Published var dupHashed = 0
    @Published var dupCandidates = 0
    @Published var dupPath = ""
    private var dupTask: Task<Void, Never>?

    func startDupScan() {
        guard !dupScanning else { return }
        dupTask?.cancel()
        dupScanning = true; dupHashed = 0; dupCandidates = 0; dupPath = ""
        let cfg = loadConfig(db)
        let roots = [NSHomeDirectory()]
        dupTask = Task { [weak self] in
            guard let self else { return }
            for await ev in DupScanner().scan(roots: roots, minMb: Int64(cfg.dup.minMb)) {
                if Task.isCancelled { return }
                switch ev {
                case .progress(let hashed, let candidates, let path):
                    self.dupHashed = hashed; self.dupCandidates = candidates; self.dupPath = path
                case .finished(let groups):
                    self.persistDupGroups(groups)
                    self.dupScanning = false
                    self.refreshDupGroups()
                }
            }
        }
    }

    func cancelDupScan() {
        dupTask?.cancel()
        dupScanning = false
    }

    /// Replaces the previous scan wholesale, matching v1: dup_groups holds one scan.
    private func persistDupGroups(_ groups: [DupGroupResult]) {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        db.prepare("DELETE FROM dup_groups").run([])
        let ins = db.prepare("INSERT INTO dup_groups(scan_ts, hash, size_mb, paths) VALUES(?,?,?,?)")
        for g in groups {
            let json = (try? JSONSerialization.data(withJSONObject: g.paths))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            ins.run([.int(ts), .text(g.hash), .int(g.sizeMb), .text(json)])
        }
    }

    /// Facts behind the quiet state. Every one is measured; a tile with no data says so
    /// rather than showing a plausible number.
    struct QuietFacts: Sendable {
        var watchingDays: Int = 0
        var freeGb: Double = 0
        var largestCacheGb: Double = 0
        var drivesQuietDays: Int? = nil     // nil = no drive events ever recorded
        var lastScanAt: Date? = nil
    }
    @Published var quietFacts = QuietFacts()

    func refreshQuietFacts() {
        var f = QuietFacts()
        if let lo = readDB.prepare("SELECT MIN(ts) m FROM proc_samples").get()?["m"], !lo.isNull {
            f.watchingDays = max(Int((Double(Date().timeIntervalSince1970 * 1000) - Double(lo.intVal)) / 86_400_000), 0)
        }
        f.freeGb = metrics.freeGb
        if let mb = readDB.prepare("SELECT MAX(size_mb) m FROM cache_samples WHERE ts = (SELECT MAX(ts) FROM cache_samples)")
            .get()?["m"], !mb.isNull {
            f.largestCacheGb = Double(mb.intVal) / 1024
        }
        // "steady" = time since the last unexpected mount/unmount, not an invented number
        if let last = readDB.prepare("SELECT MAX(ts) m FROM events WHERE kind IN ('mount','unmount')")
            .get()?["m"], !last.isNull {
            f.drivesQuietDays = max(Int((Double(Date().timeIntervalSince1970 * 1000) - Double(last.intVal)) / 86_400_000), 0)
        }
        f.lastScanAt = lastScanAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        quietFacts = f
    }

    /// Size of the database on disk, for Settings.
    var databaseSummary: String {
        let rows = (readDB.prepare("SELECT COUNT(*) n FROM proc_samples").get()?["n"]?.intVal ?? 0)
            + (readDB.prepare("SELECT COUNT(*) n FROM disk_samples").get()?["n"]?.intVal ?? 0)
            + (readDB.prepare("SELECT COUNT(*) n FROM cache_samples").get()?["n"]?.intVal ?? 0)
        let path = NSHomeDirectory() + "/Library/Application Support/com.chris.performac.v2/performac.db"
        var bytes: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            bytes += (try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? Int64) as? Int64 ?? 0
        }
        return "\(Fmt.count(Int(rows))) samples · \(Fmt.bytes(bytes))"
    }

    // MARK: Digest — real free-space history, and an honest note about it

    struct Trend: Sendable {
        var points: [Double] = []
        var window: String = ""
        var note: String = ""
        var hasEnoughHistory = false
    }
    @Published var trend = Trend()
    /// When the visible findings were last recomputed, so a card is never mistaken for live.
    @Published var findingsAt: Date? = nil
    @Published var refreshing = false

    /// Reads the boot volume's samples. Never invents a slope: below the same four days
    /// storageTrend requires, it says how little history there is instead of guessing.
    func refreshTrend() {
        let rows = readDB.prepare("SELECT ts, free_gb FROM disk_samples WHERE volume = ? ORDER BY ts")
            .all([.text("Macintosh HD")])
        let pts = rows.compactMap { r -> (Int64, Double)? in
            guard let ts = r["ts"]?.intVal, let g = r["free_gb"] else { return nil }
            return (ts, Double(g.stringVal) ?? 0)
        }
        guard let first = pts.first, let last = pts.last, pts.count >= 2 else {
            trend = Trend(points: [], window: "no history yet",
                          note: "Performac has not collected enough samples to draw anything.",
                          hasEnoughHistory: false)
            return
        }
        let spanDays = Double(last.0 - first.0) / 86_400_000
        let windowText = spanDays >= 2
            ? String(format: "%.0f days", spanDays)
            : String(format: "%.0f hours", spanDays * 24)

        // thin out to ~60 points so the line stays readable
        let step = max(1, pts.count / 60)
        let series = stride(from: 0, to: pts.count, by: step).map { pts[$0].1 }

        if spanDays < 4 {
            trend = Trend(points: series, window: windowText,
                          note: "Only \(windowText) of history — too early to call a trend. It needs about four days.",
                          hasEnoughHistory: false)
            return
        }
        // least squares on (days, freeGb)
        let xs = pts.map { Double($0.0 - first.0) / 86_400_000 }
        let ys = pts.map(\.1)
        let n = Double(xs.count)
        let mx = xs.reduce(0,+) / n, my = ys.reduce(0,+) / n
        let num = zip(xs, ys).reduce(0.0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let den = xs.reduce(0.0) { $0 + ($1 - mx) * ($1 - mx) }
        let perDay = den == 0 ? 0 : num / den
        let perWeek = -perDay * 7
        if perWeek <= 0.5 {
            trend = Trend(points: series, window: windowText,
                          note: "Free space is holding steady over the last \(windowText).",
                          hasEnoughHistory: true)
        } else {
            let weeksLeft = (ys.last ?? 0) / perWeek
            trend = Trend(points: series, window: windowText,
                          note: String(format: "Losing about %.1f GB a week. At this rate roughly %.0f weeks of headroom.", perWeek, weeksLeft),
                          hasEnoughHistory: true)
        }
    }

    // MARK: Digest coach intro (Gemini, opt-in)

    /// Read-through to MetricsStore. NOT @Published here: see MetricsStore for why.
    var metrics: Metrics { MetricsStore.shared.current }
    @Published var coachIntro: String? = nil
    @Published var coachAt: Date? = nil
    @Published var coachBusy = false
    var coachConfigured: Bool { CoachIntro.isConfigured }

    func loadCoachIntro() {
        guard let o = getSetting(db, "coachIntro")?.objectVal else { return }
        coachIntro = o["text"]?.stringVal
        coachAt = o["ts"]?.doubleVal.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// Only severity, headline and why-line leave the machine — never paths. See CoachIntro.
    func refreshCoachIntro() {
        guard CoachIntro.isConfigured, !coachBusy else { return }
        coachBusy = true
        let rows = readDB.prepare("SELECT severity, headline, why FROM findings ORDER BY id").all()
            .map { (severity: $0["severity"]?.stringVal ?? "info",
                    headline: $0["headline"]?.stringVal ?? "",
                    why: $0["why"]?.stringVal ?? "") }
        let prompt = CoachIntro.buildPrompt(rows)
        Task { [weak self] in
            let text = await CoachIntro.fetch(prompt: prompt)
            await MainActor.run {
                guard let self else { return }
                self.coachBusy = false
                guard let text else { return }          // failure keeps the previous text
                let ts = Date()
                self.coachIntro = text
                self.coachAt = ts
                setSetting(self.db, "coachIntro",
                           JSONValue.from(["text": text, "ts": ts.timeIntervalSince1970 * 1000]))
            }
        }
    }

    /// Trash one item chosen in the browser. The allowlist is that single path, so this can
    /// never widen to anything the user did not point at.
    func trashPath(_ path: String) {
        guard !trashing else { return }
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        trashing = true
        trashProgress = "Moving \(name)…"
        let db = self.db
        Task.detached(priority: .userInitiated) { [weak self] in
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let r = Trash.moveToTrash([path], allowed: [path], db: db, now: now)
            let good = r.first?.ok == true
            let msg = r.first?.message ?? "unknown error"
            await MainActor.run {
                guard let self else { return }
                self.trashing = false
                self.trashProgress = ""
                self.lastTrashSummary = good
                    ? "Moved \(name) to the Trash."
                    : "Could not move it: \(msg)"
                if good {
                    // drop it from the listing so the row does not linger as a ghost
                    self.diskEntries.removeAll { $0.name == name }
                    db.prepare("DELETE FROM scan_entries WHERE parent = ? AND name = ?")
                        .run([.text(parent), .text(name)])
                }
                trashTick(db)
                self.refreshFromDatabase()
            }
        }
    }

    // MARK: uninstaller

    @Published var apps: [InstalledApp] = []
    @Published var selectedApp: InstalledApp? = nil
    @Published var leftovers: [Leftover] = []
    @Published var appRefusal: String? = nil
    @Published var appsLoading = false
    @Published var leftoversLoading = false

    /// Names first, sizes after. Sizing every bundle walks gigabytes (Adobe, Xcode), which
    /// froze the view for seconds when it ran inline on the main actor.
    func loadApps() {
        guard apps.isEmpty, !appsLoading else { return }
        appsLoading = true
        apps = Uninstaller.listApps()            // cheap: names and bundle ids only
        Task.detached(priority: .utility) {
            let sized = Uninstaller.withSizes(Uninstaller.listApps())
            await MainActor.run { [weak self] in
                self?.apps = sized
                self?.appsLoading = false
            }
        }
    }

    /// Leftovers also walk directories, so they are measured off the main actor too.
    func selectAppAsync(_ app: InstalledApp) {
        selectedApp = app
        appRefusal = Uninstaller.refusal(for: app)
        leftovers = []
        // Measured even when the app refuses to remove anything: for a Homebrew formula the
        // refusal is the point, and what it leaves behind is still worth naming.
        leftoversLoading = true
        Task.detached(priority: .userInitiated) {
            let found = Uninstaller.leftovers(for: app)
            await MainActor.run { [weak self] in
                guard self?.selectedApp?.id == app.id else { return }   // user moved on
                self?.leftovers = found
                self?.leftoversLoading = false
            }
        }
    }

    func selectApp(_ app: InstalledApp) {
        selectedApp = app
        appRefusal = Uninstaller.refusal(for: app)
        leftovers = appRefusal == nil ? Uninstaller.leftovers(for: app) : []
    }

    /// Trash the bundle plus whichever leftovers are still ticked. Allowlist is built from
    /// exactly what is on screen, so nothing outside the shown set can be removed.
    func uninstallSelected() {
        guard let app = selectedApp, appRefusal == nil else { return }
        let chosen = leftovers.filter(\.selected)
        var items = [(name: app.name, path: app.path)]
        items += chosen.map { (name: ($0.path as NSString).lastPathComponent, path: $0.path) }
        runTrash(items, allowed: Set(items.map(\.path)))
        selectedApp = nil
        leftovers = []
        Task.detached(priority: .utility) {
            let refreshed = Uninstaller.withSizes(Uninstaller.listApps())
            await MainActor.run { [weak self] in self?.apps = refreshed }
        }
    }

    // MARK: updates

    @Published var outdated: [OutdatedItem] = []
    @Published var checkingUpdates = false
    @Published var brewMetadataAge: TimeInterval? = nil
    var brewMissing: Bool { Updates.brewPath == nil }

    func loadUpdates(force: Bool = false) {
        guard !checkingUpdates, force || outdated.isEmpty else { return }
        guard !brewMissing else { return }
        checkingUpdates = true
        Task { [weak self] in
            let items = await Updates.outdated()
            let age = Updates.metadataAge()
            await MainActor.run {
                self?.outdated = items
                self?.brewMetadataAge = age
                self?.checkingUpdates = false
            }
        }
    }

    @Published var upgrading = false
    @Published var upgradeProgress = ""
    @Published var upgradeLog: [String] = []
    @Published var upgradeSummary: String? = nil

    func setUpdateSelected(_ id: String, _ on: Bool) {
        guard let i = outdated.firstIndex(where: { $0.id == id }) else { return }
        outdated[i].selected = on
    }
    func selectAllUpdates(_ on: Bool) {
        for i in outdated.indices { outdated[i].selected = on }
    }

    /// Upgrade the ticked packages, one at a time, streaming brew's output.
    func upgradeSelected() {
        let items = outdated.filter(\.selected)
        guard !upgrading, !items.isEmpty else { return }
        upgrading = true
        upgradeLog = []
        upgradeSummary = nil
        Task { [weak self] in
            var ok = 0, failed: [String] = []
            for (i, item) in items.enumerated() {
                await MainActor.run {
                    self?.upgradeProgress = "\(item.name) (\(i + 1) of \(items.count))"
                    self?.upgradeLog.append("$ \(item.upgradeCommand)")
                }
                let good = await Updates.upgrade(item) { line in
                    Task { @MainActor in
                        guard let self else { return }
                        self.upgradeLog.append(line)
                        // brew is verbose; keep the tail rather than an unbounded transcript
                        if self.upgradeLog.count > 400 { self.upgradeLog.removeFirst(self.upgradeLog.count - 400) }
                    }
                }
                if good { ok += 1 } else { failed.append(item.name) }
            }
            let done = ok, bad = failed
            await MainActor.run {
                guard let self else { return }
                self.upgrading = false
                self.upgradeProgress = ""
                self.upgradeSummary = bad.isEmpty
                    ? "Upgraded \(done) package\(done == 1 ? "" : "s")."
                    : "Upgraded \(done); \(bad.count) failed: \(bad.prefix(3).joined(separator: ", "))"
                self.loadUpdates(force: true)     // re-read, never assume it worked
            }
        }
    }

    // MARK: cache breakdown

    @Published var breakdowns: [String: CacheBreakdown] = [:]
    @Published var inspecting: Set<String> = []

    /// Walked on demand and cached, because inspecting a quarter of a million files is not
    /// something to do for every row on the chance the user expands one.
    func inspectCache(_ entry: CacheEntry) {
        let key = entry.path
        guard breakdowns[key] == nil, !inspecting.contains(key) else { return }
        inspecting.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            let b = CacheDetail.inspect(key)
            await MainActor.run {
                self?.breakdowns[key] = b
                self?.inspecting.remove(key)
            }
        }
    }

    // MARK: the cleaner — the only place the app removes anything

    @Published var lastTrashSummary: String? = nil
    /// Trashing is not instant. The Adobe cache alone is ~250,000 files, and trashItem walks
    /// every one to record it for Put Back. Running that on the main actor froze the window
    /// until it finished, which read as "nothing happened, then everything happened".
    @Published var trashing = false
    @Published var trashProgress: String = ""

    /// Trash the selected cache entries. Allowlist is rebuilt here from the entries the UI
    /// is actually offering, so the set can never be widened by the caller.
    func trashSelected(_ selected: [CacheEntry]) {
        let allowed = Set(cacheEntries.filter(\.cleanable)
            .map { ($0.path as NSString).expandingTildeInPath })
        var items: [(name: String, path: String)] = []
        var extraAllowed = allowed
        for e in selected where e.cleanable {
            let path = (e.path as NSString).expandingTildeInPath
            let policy = Allowlist.policy(for: CacheTarget(id: "", label: e.name, path: path))
            let byId = cacheEntries.first { $0.path == e.path }
            _ = byId
            if e.contentsOnly || policy.contentsOnly {
                // empty it rather than remove it: the folder itself is undeletable
                let kids = Trash.childrenOf(path)
                extraAllowed.formUnion(kids)
                items += kids.map { (name: ($0 as NSString).lastPathComponent, path: $0) }
            } else {
                items.append((name: e.name, path: path))
            }
        }
        runTrash(items, allowed: extraAllowed)
    }

    /// Re-measure the paths just trashed and write fresh samples.
    ///
    /// This is what made trashing look slow. The move itself takes about 0.02 s — it is a
    /// rename. But the Clean list reads cache_samples, which only cacheTick writes, and that
    /// runs hourly. So the row sat there at its old size long after the files were gone, and
    /// the Trash card kept its old total. Nothing was slow; the screen was just stale.
    nonisolated private static func remeasure(_ db: DB, _ paths: [String], _ now: Int64) {
        for path in paths {
            let m = measure(path)                     // a trashed path measures 0
            let id = db.prepare("SELECT cache_id FROM cache_samples WHERE path = ? ORDER BY ts DESC LIMIT 1")
                .get([.text(path)])?["cache_id"]?.stringVal
            guard let id else { continue }
            db.prepare("INSERT INTO cache_samples(ts, cache_id, path, size_mb, newest_mtime, file_count) VALUES(?,?,?,?,?,?)")
                .run([.int(now), .text(id), .text(path), .int(Int64(m.sizeMb)),
                      m.newestMtime.map { SQLValue.int($0) } ?? .null, .int(Int64(m.fileCount))])
        }
    }

    /// Shared by every bulk trash. Off the main actor, one item at a time so the progress
    /// line names what is actually being moved rather than spinning anonymously.
    private func runTrash(_ items: [(name: String, path: String)], allowed: Set<String>) {
        guard !trashing, !items.isEmpty else { return }
        trashing = true
        trashProgress = "Preparing…"
        let db = self.db
        Task.detached(priority: .userInitiated) { [weak self] in
            var ok = 0, failed = 0
            var firstError: String?
            for (i, item) in items.enumerated() {
                await MainActor.run {
                    self?.trashProgress = "Moving \(item.name) (\(i + 1) of \(items.count))…"
                }
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                let r = Trash.moveToTrash([item.path], allowed: allowed, db: db, now: now)
                if r.first?.ok == true { ok += 1 } else {
                    failed += 1
                    if firstError == nil { firstError = r.first?.message }
                }
            }
            // fresh sizes before the UI reads them again
            Self.remeasure(db, items.map(\.path), Int64(Date().timeIntervalSince1970 * 1000))
            let done = ok, bad = failed, err = firstError
            await MainActor.run {
                guard let self else { return }
                self.trashing = false
                self.trashProgress = ""
                // name the actual reason rather than pointing at a log the user cannot see
                self.lastTrashSummary = bad == 0
                    ? "Moved \(done) item\(done == 1 ? "" : "s") to the Trash."
                    : "Moved \(done), \(bad) could not be moved: \(err ?? "unknown reason")"
                self.refreshCacheEntries()
                trashTick(self.db)          // the Trash card should reflect this immediately
                self.refreshFromDatabase()
            }
        }
    }

    // MARK: settings write path (validateSetting against the DEFAULTS template)

    func saveSetting(_ key: String, _ value: JSONValue) -> Bool {
        guard let template = defaultsTemplate.objectVal?[key],
              validateSetting(value, template) else { return false }
        setSetting(db, key, value)
        config = loadConfig(db)
        return true
    }

    // MARK: disk scan (DiskView) — streams progressively, Cancel cancels

    func startDiskScan() {
        guard !scanning else { return }
        scanTask?.cancel()
        scanning = true
        scanFiles = 0
        scanBytes = 0
        scanElapsed = 0
        scanPath = ""
        scanStart = Date()
        let root = URL(fileURLWithPath: (scanRoot as NSString).expandingTildeInPath)
        scanTask = Task { [weak self] in
            guard let self else { return }
            for await event in DiskScanner().scan(root) {
                if Task.isCancelled { return }
                switch event {
                case .progress(let s):
                    self.scanFiles = s.filesScanned
                    self.scanBytes = s.bytes
                    self.scanElapsed = Date().timeIntervalSince(self.scanStart ?? Date())
                    self.scanPath = s.currentPath
                case .finished(let sum):
                    self.buildTree(sum)
                    self.browsePath = sum.root
                    self.diskEntries = self.childrenOf(sum.root)
                    self.scanning = false
                    self.persistScan(sum.topDirectories.isEmpty ? nil : Date())
                }
            }
        }
    }

    /// Home plus every mounted volume. Externals appear here the moment they are plugged in.
    var scanTargets: [(label: String, path: String)] {
        var out: [(String, String)] = [("Home", NSHomeDirectory())]
        let vols = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for v in vols.sorted() {
            let p = "/Volumes/" + v
            // the boot volume is already reachable as Home; listing it twice is noise
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) == "/" { continue }
            out.append((v, p))
        }
        return out
    }

    /// Which readouts the menu bar shows, in a fixed display order.
    var menuBarItems: [MenuBarItem] {
        guard let raw = getSetting(db, "menuBarItems")?.objectVal?["items"]?.arrayVal else {
            return MenuBarItem.defaults
        }
        let on = Set(raw.compactMap { $0.stringVal })
        return MenuBarItem.allCases.filter { on.contains($0.rawValue) }
    }

    func setMenuBarItem(_ item: MenuBarItem, _ on: Bool) {
        var current = Set(menuBarItems.map(\.rawValue))
        if on { current.insert(item.rawValue) } else { current.remove(item.rawValue) }
        setSetting(db, "menuBarItems", JSONValue.from(["items": Array(current)]))
        objectWillChange.send()
    }

    func setDiskViewMode(_ m: DiskViewMode) {
        diskViewMode = m
        setSetting(db, "diskViewMode", JSONValue.from(["mode": m.rawValue]))
    }

    func setRightPanelMode(_ m: RightPanelMode) {
        rightPanelMode = m
        setSetting(db, "rightPanelMode", JSONValue.from(["mode": m.rawValue]))
    }

    func setScanRoot(_ path: String) {
        scanRoot = path
        setSetting(db, "diskScanRoot", JSONValue.from(["path": path]))
    }

    /// Persist the whole tree, replacing the previous scan. One transaction: ~100k rows
    /// otherwise takes minutes of individual commits.
    private func buildTree(_ sum: ScanSummary) {
        db.prepare("BEGIN").run([])
        db.prepare("DELETE FROM scan_entries").run([])
        let ins = db.prepare("INSERT INTO scan_entries(parent,name,items,bytes,is_dir,mtime) VALUES(?,?,?,?,?,?)")
        for e in sum.entries {
            ins.run([.text(e.parent), .text(e.name),
                     .int(Int64(e.isDirectory ? e.files : 0)), .int(e.bytes),
                     .int(e.isDirectory ? 1 : 0), .int(e.mtime)])
        }
        db.prepare("COMMIT").run([])
    }

    /// Reads from the table, so a scan from last week browses exactly like a fresh one.
    func childrenOf(_ path: String) -> [SizeEntry] {
        readDB.prepare("SELECT name, items, bytes, is_dir, mtime FROM scan_entries WHERE parent = ? ORDER BY bytes DESC")
            .all([.text(path)])
            .map { r in
                let isDir = (r["is_dir"]?.intVal ?? 1) == 1
                let name = r["name"]?.stringVal ?? ""
                return SizeEntry(
                    name: name,
                    items: Int(r["items"]?.intVal ?? 0),
                    bytes: r["bytes"]?.intVal ?? 0,
                    symbol: isDir ? "folder.fill" : "doc.fill",
                    kind: Self.fileKind(forPath: (path as NSString).appendingPathComponent(name)),
                    mtime: r["mtime"]?.intVal ?? 0)
            }
    }

    // MARK: muted processes

    /// Processes the hog and idle rules should stop reporting.
    ///
    /// Kept as the rules' own ignore list rather than a separate mute table, so a muted
    /// process is genuinely never evaluated instead of being computed and then hidden.
    var ignoredProcesses: [String] {
        let cfg = loadConfig(readDB)
        let builtin = Set(Config.defaults.hog.ignore)
        return cfg.hog.ignore.filter { !builtin.contains($0) }.sorted()
    }

    func ignoreProcess(_ name: String) {
        var cfg = loadConfig(readDB)
        guard !cfg.hog.ignore.contains(name) else { return }
        cfg.hog.ignore.append(name)
        setSetting(db, "hog", JSONValue.from([
            "cpuPct": cfg.hog.cpuPct, "minMinutes": Double(cfg.hog.minMinutes),
            "lookbackHours": Double(cfg.hog.lookbackHours), "ignore": cfg.hog.ignore,
        ]))
        refreshFromDatabase()
    }

    func unignoreProcess(_ name: String) {
        var cfg = loadConfig(readDB)
        cfg.hog.ignore.removeAll { $0 == name }
        setSetting(db, "hog", JSONValue.from([
            "cpuPct": cfg.hog.cpuPct, "minMinutes": Double(cfg.hog.minMinutes),
            "lookbackHours": Double(cfg.hog.lookbackHours), "ignore": cfg.hog.ignore,
        ]))
        refreshFromDatabase()
    }

    // MARK: configurable surfaces

    private func graphs(_ key: String, _ fallback: [GraphKind]) -> [GraphKind] {
        guard let raw = getSetting(readDB, key)?.objectVal?["items"]?.arrayVal else { return fallback }
        let on = Set(raw.compactMap { $0.stringVal })
        return GraphKind.allCases.filter { on.contains($0.rawValue) }
    }
    private func setGraph(_ key: String, _ current: [GraphKind], _ g: GraphKind, _ on: Bool) {
        var set = Set(current.map(\.rawValue))
        if on { set.insert(g.rawValue) } else { set.remove(g.rawValue) }
        setSetting(db, key, JSONValue.from(["items": Array(set)]))
        objectWillChange.send()
    }

    /// Which cells the popover's top strip shows.
    var metricTiles: [MetricTileKind] {
        guard let raw = getSetting(readDB, "metricTiles")?.objectVal?["items"]?.arrayVal else {
            return MetricTileKind.defaults
        }
        let on = Set(raw.compactMap { $0.stringVal })
        return MetricTileKind.allCases.filter { on.contains($0.rawValue) }
    }
    func setMetricTile(_ t: MetricTileKind, _ on: Bool) {
        var set = Set(metricTiles.map(\.rawValue))
        if on { set.insert(t.rawValue) } else { set.remove(t.rawValue) }
        setSetting(db, "metricTiles", JSONValue.from(["items": Array(set)]))
        objectWillChange.send()
    }

    var popoverGraphs: [GraphKind] { graphs("popoverGraphs", GraphKind.popoverDefaults) }
    func setPopoverGraph(_ g: GraphKind, _ on: Bool) { setGraph("popoverGraphs", popoverGraphs, g, on) }
    var dashboardGraphs: [GraphKind] { graphs("dashboardGraphs", GraphKind.dashboardDefaults) }
    func setDashboardGraph(_ g: GraphKind, _ on: Bool) { setGraph("dashboardGraphs", dashboardGraphs, g, on) }

    /// Whether the popover lists findings under its graphs.
    var popoverShowsFindings: Bool {
        getSetting(readDB, "popoverFindings")?.objectVal?["on"]?.boolVal ?? true
    }
    func setPopoverShowsFindings(_ on: Bool) {
        setSetting(db, "popoverFindings", JSONValue.from(["on": on]))
        objectWillChange.send()
    }

    // MARK: browse history
    //
    // Real back/forward, so the mouse's side buttons and a two-finger swipe do what they do
    // everywhere else. Going somewhere new pushes the current location and clears forward,
    // the same rule a browser uses.
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Descend into a folder. Files and empty folders are not navigable.
    func browse(into name: String) {
        navigate(to: (browsePath as NSString).appendingPathComponent(name))
    }

    /// Jump to any ancestor from the breadcrumb.
    func browse(to path: String) { navigate(to: path) }

    private func navigate(to path: String) {
        guard path != browsePath else { return }
        let kids = childrenOf(path)
        guard !kids.isEmpty else { return }
        backStack.append(browsePath)
        forwardStack.removeAll()
        browsePath = path
        diskEntries = kids
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        let kids = childrenOf(prev)
        guard !kids.isEmpty else { return }
        forwardStack.append(browsePath)
        browsePath = prev
        diskEntries = kids
        objectWillChange.send()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        let kids = childrenOf(next)
        guard !kids.isEmpty else { return }
        backStack.append(browsePath)
        browsePath = next
        diskEntries = kids
        objectWillChange.send()
    }

    /// Breadcrumb components from the scan root down to where we are.
    var breadcrumb: [(name: String, path: String)] {
        let rootPath = (scanRoot as NSString).expandingTildeInPath
        guard browsePath.hasPrefix(rootPath) else {
            return [((rootPath as NSString).lastPathComponent, rootPath)]
        }
        var out: [(String, String)] = [((rootPath as NSString).lastPathComponent, rootPath)]
        let rest = String(browsePath.dropFirst(rootPath.count)).split(separator: "/")
        var acc = rootPath
        for part in rest {
            acc = (acc as NSString).appendingPathComponent(String(part))
            out.append((String(part), acc))
        }
        return out
    }

    func cancelDiskScan() {
        scanTask?.cancel()
        scanning = false
    }

    /// The Disk view is on screen. A scan only starts here when the user has opted in —
    /// scanning ~900 GB is minutes of sustained I/O and must never be something the app
    /// does merely because a window opened.
    func diskViewAppeared() {
        if autoRefreshScan && !scanning { startDiskScan() }
    }

    /// Switching tabs does NOT stop a scan. A scan is minutes of work the user asked for;
    /// killing it because they looked at another view would waste it silently. Cancel is
    /// explicit (the button) or at quit. Results land whenever it finishes.
    func diskViewDisappeared() {}

    func setAutoRefreshScan(_ on: Bool) {
        autoRefreshScan = on
        setSetting(db, "diskScanAutoRefresh", JSONValue.from(["on": on]))
        if on && !scanning { startDiskScan() }
    }

    /// Persist the entry list so reopening the view shows the last result instead of a
    /// blank screen — labelled as of its scan time, never presented as current.
    private func persistScan(_ when: Date?) {
        let ts = Int64((when ?? Date()).timeIntervalSince1970 * 1000)
        lastScanAt = ts
        // Only the metadata: the tree itself is already in scan_entries.
        setSetting(db, "lastDiskScan", JSONValue.from(["ts": Double(ts), "root": scanRoot]))
    }

    func loadPersistedScan() {
        autoRefreshScan = getSetting(db, "diskScanAutoRefresh")?.objectVal?["on"]?.boolVal ?? false
        if let saved = getSetting(db, "diskScanRoot")?.objectVal?["path"]?.stringVal { scanRoot = saved }
        if let m = getSetting(db, "diskViewMode")?.objectVal?["mode"]?.stringVal,
           let mode = DiskViewMode(rawValue: m) { diskViewMode = mode }
        else if getSetting(db, "diskViewMode") != nil { diskViewMode = .outline }   // retired mode
        if let r = getSetting(db, "rightPanelMode")?.objectVal?["mode"]?.stringVal,
           let rm = RightPanelMode(rawValue: r) { rightPanelMode = rm }
        guard let o = getSetting(db, "lastDiskScan")?.objectVal else { return }
        lastScanAt = o["ts"]?.doubleVal.map { Int64($0) }
        // The tree lives in scan_entries, so a stale scan is fully browsable on relaunch.
        let root = (o["root"]?.stringVal ?? scanRoot as String)
        browsePath = (root as NSString).expandingTildeInPath
        diskEntries = childrenOf(browsePath)
    }

    /// Heuristic file-kind buckets for the treemap legend — folder-name based.
    static func fileKind(forPath path: String) -> FileKind {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.contains("movie") || name.contains("video") || name.contains("footage") { return .video }
        if name.contains("picture") || name.contains("photo") { return .image }
        if name.contains("cache") || name == "library" { return .cache }
        if name.contains("document") || name.contains("desktop") || name.contains("download") { return .document }
        return .other
    }

    // MARK: Full Disk Access — real state, not a hardcoded pill

    static func checkFullDiskAccess() -> Bool {
        // ~/Library/Safari is FDA-protected; a plain read succeeds only with the grant.
        (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Safari")) != nil
    }
}

/// v1's live database — the seeding source. Read-only, opened only through the
/// online-backup copy path.
let V1_DATABASE_PATH = "/Users/you/Data C (General)/Projects/Personal/Performac/performac.db"
