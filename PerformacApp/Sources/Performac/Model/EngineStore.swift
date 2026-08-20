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

    init(db: DB? = nil) {
        let path = db == nil ? copyV1DatabaseIfNeeded(v1Path: V1_DATABASE_PATH) : nil
        self.db = db ?? DB(path: path!)
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
            entries.append(CacheEntry(
                name: meta.app,
                bytes: bytes,
                age: Rules.ageText(ageDays) + (mtime == nil ? "" : " ago"),
                safe: meta.safety == "safe",
                why: meta.clearing.isEmpty ? "Measured by Performac's cache walker." : meta.clearing,
                path: row["path"]?.stringVal ?? ""))
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
                }
            }
        }
    }

    func cancelDiskScan() {
        scanTask?.cancel()
        scanning = false
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
