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
            findings.append(Finding(
                severity: severity == "red" ? .red : severity == "amber" ? .amber : .info,
                headline: row["headline"]?.stringVal ?? "",
                why: row["why"]?.stringVal ?? "",
                link: link))
            kinds.append(row["kind"]?.stringVal ?? "")
        }
        // v1's split: live = time-sensitive kinds, digest = everything
        let liveKinds: Set<String> = ["drive", "thermal", "backup"]
        live = zip(findings, kinds).filter { liveKinds.contains($0.1) }.map { $0.0 }
        digest = findings
        refreshCacheEntries()
        refreshDupGroups()
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        scanTask = Task { [weak self] in
            guard let self else { return }
            for await event in DiskScanner().scan(home) {
                if Task.isCancelled { return }
                switch event {
                case .progress(let s):
                    self.scanFiles = s.filesScanned
                    self.scanBytes = s.bytes
                    self.scanElapsed = Date().timeIntervalSince(self.scanStart ?? Date())
                    self.scanPath = s.currentPath
                case .finished(let sum):
                    self.diskEntries = sum.topDirectories.map { d in
                        SizeEntry(
                            name: (d.path as NSString).lastPathComponent,
                            items: d.files,
                            bytes: d.bytes,
                            kind: Self.fileKind(forPath: d.path))
                    }
                    self.scanning = false
                    self.persistScan(sum.topDirectories.isEmpty ? nil : Date())
                }
            }
        }
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
        let entries: [[String: Any]] = diskEntries.map {
            ["name": $0.name, "items": $0.items, "bytes": Double($0.bytes), "kind": $0.kind.rawValue]
        }
        setSetting(db, "lastDiskScan", JSONValue.from(["ts": Double(ts), "entries": entries]))
    }

    func loadPersistedScan() {
        autoRefreshScan = getSetting(db, "diskScanAutoRefresh")?.objectVal?["on"]?.boolVal ?? false
        guard let o = getSetting(db, "lastDiskScan")?.objectVal else { return }
        lastScanAt = o["ts"]?.doubleVal.map { Int64($0) }
        diskEntries = (o["entries"]?.arrayVal ?? []).compactMap { v in
            guard let e = v.objectVal, let name = e["name"]?.stringVal else { return nil }
            return SizeEntry(
                name: name,
                items: Int(e["items"]?.doubleVal ?? 0),
                bytes: Int64(e["bytes"]?.doubleVal ?? 0),
                kind: FileKind(rawValue: e["kind"]?.stringVal ?? "") ?? .other)
        }
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
