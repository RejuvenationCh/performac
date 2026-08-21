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
        loadPersistedScan()   // reopening shows the last result, labelled as a snapshot
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
        let rows = db.prepare("SELECT id, kind, severity, headline, why, detail, link_kind, link_target, updated FROM findings ORDER BY updated DESC").all()
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
        config = loadConfig(db)
        fdaGranted = EngineStore.checkFullDiskAccess()
    }

    // MARK: Clean view — latest cache sample per target + v1's meta copy

    private func refreshCacheEntries() {
        var entries: [CacheEntry] = []
        let rows = db.prepare("SELECT * FROM cache_samples ORDER BY ts DESC").all()
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
                safe: policy.safe,
                why: policy.consequence,
                path: path,
                cleanable: policy.cleanable))
        }
        cacheEntries = entries
    }

    // MARK: Duplicates view — v1's last scan rows (the rescanner arrives with Clean)

    private func refreshDupGroups() {
        let rows = db.prepare("SELECT * FROM dup_groups WHERE scan_ts = (SELECT MAX(scan_ts) FROM dup_groups) ORDER BY size_mb DESC").all()
        dupScanAt = db.prepare("SELECT MAX(scan_ts) m FROM dup_groups").get()?["m"]?.intVal
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

    // MARK: Digest — real free-space history, and an honest note about it

    struct Trend: Sendable {
        var points: [Double] = []
        var window: String = ""
        var note: String = ""
        var hasEnoughHistory = false
    }
    @Published var trend = Trend()

    /// Reads the boot volume's samples. Never invents a slope: below the same four days
    /// storageTrend requires, it says how little history there is instead of guessing.
    func refreshTrend() {
        let rows = db.prepare("SELECT ts, free_gb FROM disk_samples WHERE volume = ? ORDER BY ts")
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

    // MARK: uninstaller

    @Published var apps: [InstalledApp] = []
    @Published var selectedApp: InstalledApp? = nil
    @Published var leftovers: [Leftover] = []
    @Published var appRefusal: String? = nil

    func loadApps() {
        if apps.isEmpty { apps = Uninstaller.installedApps() }
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
        let chosen = leftovers.filter(\.selected).map(\.path)
        let paths = [app.path] + chosen
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let results = Trash.moveToTrash(paths, allowed: Set(paths), db: db, now: now)
        let ok = results.filter(\.ok).count
        lastTrashSummary = "Moved \(ok) of \(paths.count) items to the Trash."
        apps = Uninstaller.installedApps()
        selectedApp = nil
        leftovers = []
    }

    // MARK: the cleaner — the only place the app removes anything

    @Published var lastTrashSummary: String? = nil

    /// Trash the selected cache entries. Allowlist is rebuilt here from the entries the UI
    /// is actually offering, so the set can never be widened by the caller.
    func trashSelected(_ selected: [CacheEntry]) {
        let allowed = Set(cacheEntries.filter(\.cleanable)
            .map { ($0.path as NSString).expandingTildeInPath })
        let paths = selected.filter(\.cleanable).map { ($0.path as NSString).expandingTildeInPath }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let results = Trash.moveToTrash(paths, allowed: allowed, db: db, now: now)
        let ok = results.filter(\.ok).count
        let failed = results.count - ok
        lastTrashSummary = failed == 0
            ? "Moved \(ok) item\(ok == 1 ? "" : "s") to the Trash."
            : "Moved \(ok), could not move \(failed) — see Trash history."
        refreshCacheEntries()
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
        let ins = db.prepare("INSERT INTO scan_entries(parent,name,items,bytes,is_dir) VALUES(?,?,?,?,?)")
        for e in sum.entries {
            ins.run([.text(e.parent), .text(e.name),
                     .int(Int64(e.isDirectory ? e.files : 0)), .int(e.bytes),
                     .int(e.isDirectory ? 1 : 0)])
        }
        db.prepare("COMMIT").run([])
    }

    /// Reads from the table, so a scan from last week browses exactly like a fresh one.
    func childrenOf(_ path: String) -> [SizeEntry] {
        db.prepare("SELECT name, items, bytes, is_dir FROM scan_entries WHERE parent = ? ORDER BY bytes DESC")
            .all([.text(path)])
            .map { r in
                let isDir = (r["is_dir"]?.intVal ?? 1) == 1
                let name = r["name"]?.stringVal ?? ""
                return SizeEntry(
                    name: name,
                    items: Int(r["items"]?.intVal ?? 0),
                    bytes: r["bytes"]?.intVal ?? 0,
                    symbol: isDir ? "folder.fill" : "doc.fill",
                    kind: Self.fileKind(forPath: (path as NSString).appendingPathComponent(name)))
            }
    }

    /// Descend into a folder. Files and empty folders are not navigable.
    func browse(into name: String) {
        let next = (browsePath as NSString).appendingPathComponent(name)
        guard !childrenOf(next).isEmpty else { return }
        browsePath = next
        diskEntries = childrenOf(next)
    }

    /// Jump to any ancestor from the breadcrumb.
    func browse(to path: String) {
        let kids = childrenOf(path)
        guard !kids.isEmpty else { return }
        browsePath = path
        diskEntries = kids
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

    /// Leaving the view stops the scan. Nothing keeps reading the disk in the background.
    func diskViewDisappeared() {
        if scanning { cancelDiskScan() }
    }

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
