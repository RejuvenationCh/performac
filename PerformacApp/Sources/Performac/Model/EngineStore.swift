// Model/EngineStore.swift: the single observable store. Owns the v2 database and
// publishes what the views need. The sampler runs off the main actor and writes to
// SQLite; after each tick the store refreshes on the main actor by reading the
// findings table, cheap by design, never triggers a scan.
import SwiftUI
import Foundation
import AppKit

@MainActor
final class EngineStore: ObservableObject {
    static let shared = EngineStore()

    @Published var digest: [Finding] = []
    /// Which screen the window shows. Here rather than in the view so a card's link-out can
    /// navigate to Clean, and so closing the window does not reset the choice.
    ///
    /// Persisted in UserDefaults rather than the settings table: it is read before the first
    /// render and written on every tab click, which is the wrong traffic for SQLite.
    @Published var route: Route = UserDefaults.standard.string(forKey: "route")
        .flatMap(Route.init(rawValue:)) ?? .overview {
        didSet { UserDefaults.standard.set(route.rawValue, forKey: "route") }
    }
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
    /// When each root was last scanned, keyed by its path. Scans accumulate now, so there is
    /// no single "last scan": Home and the T7 each have their own.
    @Published var scanTimes: [String: Int64] = [:]

    /// Roots whose stored tree came from a scan that was stopped early. Kept separately so the
    /// picker can say "partial" instead of printing an age that implies the whole drive.
    @Published var partialRoots: Set<String> = []

    /// The age of what is currently on screen. For the combined root that is the age of its
    /// STALEST drive: the view is only as current as the oldest thing in it, and rounding
    /// that up to the newest would be a stale number wearing a fresh label.
    var lastScanAt: Int64? {
        if scanRoot == Self.allDrives {
            return allDriveRoots.compactMap { scanTimes[$0] }.min()
        }
        return scanTimes[(scanRoot as NSString).expandingTildeInPath]
    }

    /// Roots with a stored tree, so the picker can say which targets need a scan first.
    var scannedRoots: Set<String> { Set(scanTimes.keys) }

    /// What the picker says under each target. The whole point of keeping trees per root is
    /// that switching is free, so the menu has to show which ones are already there.
    var scanTargetNotes: [String: String] {
        func ago(_ ts: Int64) -> String {
            Ago.text(Date(timeIntervalSince1970: Double(ts) / 1000))
        }
        var out: [String: String] = [:]
        for t in scanTargets {
            if t.path == Self.allDrives {
                let roots = allDriveRoots
                let have = roots.compactMap { scanTimes[$0] }
                if have.isEmpty { out[t.path] = "nothing scanned yet" }
                else if have.count < roots.count {
                    out[t.path] = "\(have.count) of \(roots.count) scanned"
                } else {
                    // the combined view is only as fresh as its stalest drive
                    out[t.path] = ago(have.min()!)
                }
            } else {
                let p = (t.path as NSString).expandingTildeInPath
                let suffix = partialRoots.contains(p) ? ", partial" : ""
                out[t.path] = scanTimes[p].map { ago($0) + suffix } ?? "not scanned"
            }
        }
        return out
    }
    /// Only meaningful once a scan exists; persisted so it survives relaunch.
    @Published var autoRefreshScan = false

    init(db: DB? = nil) {
        let path = db == nil ? copyV1DatabaseIfNeeded(v1Path: V1_DATABASE_PATH) : nil
        self.db = db ?? DB(path: path!)
        // Separate handle for browsing reads so the UI never waits on the sampler's lock.
        self.readDB = (db == nil && path != nil) ? DB(path: path!, readOnly: true) : self.db
        loadPersistedScan()   // reopening shows the last result, labelled as a snapshot
        mountedVolumes = Self.volumePaths()
        watchVolumes()
    }

    deinit { volumeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

    // MARK: drives arriving and leaving

    /// The externals currently in /Volumes. Published, because scanTargets used to read the
    /// directory on every render, which meant a drive plugged in while the Disk tab was open
    /// never showed up, since nothing told SwiftUI anything had changed.
    @Published private(set) var mountedVolumes: [String] = []

    /// A drive that appeared since the view was last looking, so it can be offered directly
    /// rather than found in a menu. Cleared once it is scanned, dismissed, or unplugged.
    @Published var newlyMounted: String? = nil

    /// nonisolated so deinit can unregister: the tokens are written once during init on the
    /// main actor and only ever read again on the way out.
    nonisolated(unsafe) private var volumeObservers: [NSObjectProtocol] = []

    /// Externals only. Everything in /Volumes except the boot volume, which is a symlink to /
    /// and is already reachable as Home.
    static func volumePaths() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [])
            .sorted()
            .map { "/Volumes/" + $0 }
            .filter { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0)) != "/" }
    }

    /// NSWorkspace posts these on the main thread, so no polling and no extra process.
    ///
    /// macOS mounts internal APFS volumes constantly and fires the same notification for them,
    /// but those land under /System/Volumes and so never change this list: comparing the
    /// computed list rather than trusting the notification filters that noise for free.
    private func watchVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
    }

    func refreshVolumes() { apply(volumes: Self.volumePaths()) }

    private func apply(volumes now: [String]) {
        guard now != mountedVolumes else { return }
        let appeared = now.filter { !mountedVolumes.contains($0) }
        mountedVolumes = now
        // the newest arrival is the one worth offering; an unplug clears a stale offer
        if let first = appeared.first { newlyMounted = first }
        if let n = newlyMounted, !now.contains(n) { newlyMounted = nil }
        // a drive that left should not keep a browser pointed into it
        if scanRoot != Self.allDrives, !FileManager.default.fileExists(atPath: scanRoot) {
            setScanRoot(NSHomeDirectory())
        }
    }

    func dismissNewDrive() { newlyMounted = nil }

    /// Seams for the checks: the arrival logic is worth testing without a real drive to plug in.
    var mountedVolumesForChecks: [String] {
        get { mountedVolumes }
        set { mountedVolumes = newValue }
    }
    func applyVolumesForChecks(_ paths: [String]) { apply(volumes: paths) }

    /// Switch to the drive that just appeared and scan it.
    func scanNewDrive() {
        guard let path = newlyMounted else { return }
        newlyMounted = nil
        setScanRoot(path)
        startDiskScan()
    }

    /// Perform a card's one link-out. Reveals or navigates only: `.disableAgent` acts, so
    /// FindingCard intercepts it for confirmation before this is ever called with one.
    func openLink(_ link: FindingLink) {
        switch link {
        case .reveal(let path):
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        case .activityMonitor:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        case .clean:
            route = .clean
        case .loginSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        case .disableAgent:
            break   // never acts from here: see disableAgent(_:)
        }
    }

    // MARK: refresh from SQLite (cheap, findings table only)

    func refreshFromDatabase() {
        let rows = readDB.prepare("SELECT id, kind, severity, headline, why, detail, link_kind, link_target, updated FROM findings ORDER BY updated DESC").all()
        var findings: [Finding] = []
        for row in rows {
            let severity = row["severity"]?.stringVal ?? "info"
            // The target comes along now. Reading only the kind is what left every card with
            // an accent-coloured button that did nothing.
            let link = FindingLink(kind: row["link_kind"]?.stringVal ?? "",
                                   target: row["link_target"]?.stringVal)
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
        }
        digest = findings
        refreshCacheEntries()
        refreshDupGroups()
        refreshTrend()
        refreshQuietFacts()
        findingsAt = Date()
        config = loadConfig(readDB)
        fdaGranted = EngineStore.checkFullDiskAccess()
    }

    // MARK: Clean view, latest cache sample per target + v1's meta copy

    private func refreshCacheEntries() {
        var entries: [CacheEntry] = []
        let rows = readDB.prepare("SELECT * FROM cache_samples ORDER BY ts DESC").all()
        var seen = Set<String>()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for row in rows {
            guard let id = row["cache_id"]?.stringVal, !seen.contains(id) else { continue }
            seen.insert(id)
            let meta = Rules.cacheMeta(id)
            // size_mb is MiB: measure() divides by 1_048_576 and CacheDetail multiplies back
            // by it. Converting with 1_000_000 here under-reported every cache by 4.8%.
            let bytes = Int64((row["size_mb"]?.intVal ?? 0)) * 1_048_576
            if bytes <= 0 { continue }
            let mtime = row["newest_mtime"]?.isNull == false ? row["newest_mtime"]?.intVal : nil
            let ageDays = mtime.map { Double(now - $0) / Double(Rules.DAY) }
            let path = row["path"]?.stringVal ?? ""
            // The cleaner's allowlist decides, not the measurement registry. Anything
            // without an explicit policy is shown but cannot be selected or trashed.
            let policy = Allowlist.policy(for: CacheTarget(id: id, label: meta.app, path: path,
                                                           safety: meta.safety))
            entries.append(CacheEntry(
                name: meta.app,
                bytes: bytes,
                age: Rules.ageTextAgo(ageDays),
                ageDays: ageDays ?? 0,
                safe: policy.safe,
                why: policy.consequence,
                path: path,
                cacheID: id,
                cleanable: policy.cleanable))
        }
        cacheEntries = Self.disambiguated(entries)
    }

    /// Several distinct caches can share one label: every `lr-*` id renders as
    /// "Lightroom Classic" via `LR_META`. Give each same-named group a suffix drawn from its
    /// own path so the rows are no longer indistinguishable.
    /// Where a cache lives, in the terms a person uses: the drive, or the top folder in home.
    private static func locationName(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        if p.hasPrefix("/Volumes/") {
            return p.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? "a drive"
        }
        let home = NSHomeDirectory()
        if p.hasPrefix(home + "/") {
            let rest = p.dropFirst(home.count + 1).split(separator: "/").map(String.init)
            return rest.first ?? "Home"
        }
        return (p as NSString).pathComponents.filter { $0 != "/" }.first ?? p
    }

    /// Several caches can share a display name: every Lightroom catalog is "Lightroom Classic".
    /// Three indistinguishable rows is a real problem, but the first attempt at fixing it fell
    /// back to the cache id, which is a hundred-character slug of the whole path and put the
    /// user's folder tree in the row title.
    ///
    /// The catalog's own folder is the natural label. When two catalogs share even that, which
    /// happens when one has been copied to another drive, the thing that actually differs is
    /// where it lives, so that gets added and nothing longer ever does.
    static func disambiguated(_ entries: [CacheEntry]) -> [CacheEntry] {
        var byName: [String: [Int]] = [:]
        for (i, e) in entries.enumerated() { byName[e.name, default: []].append(i) }
        let generic: Set<String> = ["Cache", "Caches", "Data", "tmp", "Lr", "Lightroom"]
        var out = entries

        for (name, idxs) in byName where idxs.count > 1 {
            // Step one: the containing folder, skipping names that say nothing.
            var qualifier: [Int: String] = [:]
            for i in idxs {
                let parent = (out[i].path as NSString).deletingLastPathComponent as NSString
                let comps = parent.pathComponents.filter { $0 != "/" }
                qualifier[i] = comps.reversed().first { !generic.contains($0) }
                    ?? comps.last ?? locationName(out[i].path)
            }
            // Step two: add the drive or top folder only for the ones still colliding.
            var counts: [String: Int] = [:]
            for i in idxs { counts[qualifier[i]!, default: 0] += 1 }
            for i in idxs where counts[qualifier[i]!]! > 1 {
                qualifier[i] = "\(qualifier[i]!), \(locationName(out[i].path))"
            }
            // Step three: if two are genuinely indistinguishable, number them rather than
            // print anything longer.
            var seen: [String: Int] = [:]
            for i in idxs {
                let q = qualifier[i]!
                seen[q, default: 0] += 1
                let n = seen[q]!
                out[i].name = n == 1 ? "\(name) (\(q))" : "\(name) (\(q) \(n))"
            }
        }
        return out
    }

    // MARK: Duplicates view, v1's last scan rows (the rescanner arrives with Clean)

    private func refreshDupGroups() {
        let rows = readDB.prepare("SELECT * FROM dup_groups WHERE scan_ts = (SELECT MAX(scan_ts) FROM dup_groups) ORDER BY size_mb DESC").all()
        dupScanAt = readDB.prepare("SELECT MAX(scan_ts) m FROM dup_groups").get()?["m"]?.intVal
        dupGroups = rows.compactMap { row in
            guard let pathsText = row["paths"]?.stringVal,
                  let data = pathsText.data(using: .utf8),
                  let paths = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { return nil }
            let name = (paths.first as NSString?)?.lastPathComponent ?? "file"
            return DupGroup(bytes: (row["size_mb"]?.intVal ?? 0) * 1_048_576, name: name, paths: paths)
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

    // MARK: duplicate scan, on-demand, cancels when you leave, like the disk scan

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
        /// Bytes, like every other size in the app. See `spaceBytes(at:)`.
        var freeBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var largestCacheBytes: Int64 = 0
        var drivesQuietDays: Int? = nil     // nil = no drive events ever recorded
        var lastScanAt: Date? = nil
    }
    @Published var quietFacts = QuietFacts()

    func refreshQuietFacts() {
        var f = QuietFacts()
        if let lo = readDB.prepare("SELECT MIN(ts) m FROM proc_samples").get()?["m"], !lo.isNull {
            f.watchingDays = max(Int((Double(Date().timeIntervalSince1970 * 1000) - Double(lo.intVal)) / 86_400_000), 0)
        }
        (f.freeBytes, f.totalBytes) = bootSpaceBytes
        if let mb = readDB.prepare("SELECT MAX(size_mb) m FROM cache_samples WHERE ts = (SELECT MAX(ts) FROM cache_samples)")
            .get()?["m"], !mb.isNull {
            f.largestCacheBytes = mb.intVal * 1_048_576
        }
        // "steady" = time since the last unexpected mount/unmount, not an invented number
        if let last = readDB.prepare("SELECT MAX(ts) m FROM events WHERE kind IN ('mount','unmount')")
            .get()?["m"], !last.isNull {
            f.drivesQuietDays = max(Int((Double(Date().timeIntervalSince1970 * 1000) - Double(last.intVal)) / 86_400_000), 0)
        }
        f.lastScanAt = lastScanAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        quietFacts = f
    }

    /// Where the database lives. Named so Settings can reveal it rather than offering a
    /// Reveal button wired to an empty closure.
    static let databasePath =
        NSHomeDirectory() + "/Library/Application Support/com.chris.performac.v2/performac.db"

    /// Size of the database on disk, for Settings.
    var databaseSummary: String {
        let rows = (readDB.prepare("SELECT COUNT(*) n FROM proc_samples").get()?["n"]?.intVal ?? 0)
            + (readDB.prepare("SELECT COUNT(*) n FROM disk_samples").get()?["n"]?.intVal ?? 0)
            + (readDB.prepare("SELECT COUNT(*) n FROM cache_samples").get()?["n"]?.intVal ?? 0)
        let path = Self.databasePath
        var bytes: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            bytes += (try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? Int64) as? Int64 ?? 0
        }
        return "\(Fmt.count(Int(rows))) samples · \(Fmt.bytes(bytes))"
    }

    // MARK: Digest, real free-space history, and an honest note about it

    struct Trend: Sendable {
        var points: [TrendPoint] = []
        var window: String = ""
        var note: String = ""
        var hasEnoughHistory = false
        /// The chart is boot-volume only, but cards above it can be about an external drive.
        /// Unlabelled, "holding steady" sat directly under "External SSD is losing 210 GB a
        /// week" and the two read as contradicting each other.
        var volume: String = Trend.bootVolume

        /// The name `disk_samples` records the boot disk under, read from the volume itself so
        /// it matches what the sampler writes and what Finder shows. On Trend rather than the
        /// store because the store is @MainActor and Trend is Sendable: a main-actor static
        /// cannot be a default for a nonisolated value.
        static let bootVolume = bootVolumeName()
    }
    @Published var trend = Trend()
    /// When the visible findings were last recomputed, so a card is never mistaken for live.
    @Published var findingsAt: Date? = nil
    @Published var refreshing = false

    /// Reads the boot volume's samples. Never invents a slope: below the same four days
    /// storageTrend requires, it says how little history there is instead of guessing.
    func refreshTrend() {
        let rows = readDB.prepare("SELECT ts, free_gb FROM disk_samples WHERE volume = ? ORDER BY ts")
            .all([.text(Trend.bootVolume)])
        let pts = rows.compactMap { r -> (Int64, Double)? in
            guard let ts = r["ts"]?.intVal, let g = r["free_gb"] else { return nil }
            return (ts, g.doubleVal)   // stored as REAL: stringVal is "" for those, which made every point 0
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

        // thin out to ~60 points so the line stays readable. Timestamps ride along now: the
        // chart is hoverable, and a point that cannot say when it was taken is half a reading.
        let step = max(1, pts.count / 60)
        let series = stride(from: 0, to: pts.count, by: step)
            .map { TrendPoint(ts: pts[$0].0, freeGiB: pts[$0].1) }

        if spanDays < 4 {
            trend = Trend(points: series, window: windowText,
                          note: "Only \(windowText) of history: too early to call a trend. It needs about four days.",
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
            let weeksLeft = (ys.last ?? 0) / perWeek   // a ratio, so the unit cancels
            // perWeek is GiB, like the column it came from. Printing it as "GB" put this
            // sentence 7.4% out from every other size on the screen.
            let perWeekText = Fmt.bytes(Int64(perWeek * 1_073_741_824))
            trend = Trend(points: series, window: windowText,
                          note: String(format: "Losing about %@ a week. At this rate roughly %.0f weeks of headroom.",
                                       perWeekText, weeksLeft),
                          hasEnoughHistory: true)
        }
    }

    /// Capacity of the volume holding `path`, in **bytes**, read fresh: statfs is one syscall.
    ///
    /// Bytes, not GB. These used to be returned as GiB (blocks × f_bsize ÷ 2^30) while `Fmt`
    /// prints decimal GB, so whether a figure was 7.4% high or low depended on which screen
    /// you read it on. One unit end to end leaves nothing to convert.
    static func spaceBytes(at path: String) -> (free: Int64, total: Int64) {
        // "/" is the sealed read-only system volume on modern macOS; the writable half that
        // the user actually fills is the Data volume.
        let target = (path == "/" || path == allDrives) ? "/System/Volumes/Data" : path
        var fs = statfs()
        guard statfs(target, &fs) == 0 else { return (0, 0) }
        let block = Int64(fs.f_bsize)
        return (Int64(fs.f_bavail) * block, Int64(fs.f_blocks) * block)
    }

    var bootSpaceBytes: (free: Int64, total: Int64) { Self.spaceBytes(at: "/System/Volumes/Data") }

    /// The volume the picker is pointed at, so the Disk toolbar describes the drive being
    /// browsed instead of always reporting the internal disk beside an external drive's name.
    var scanRootSpaceBytes: (free: Int64, total: Int64) { Self.spaceBytes(at: scanRoot) }

    /// Trash one item chosen in the browser. The allowlist is that single path, so this can
    /// never widen to anything the user did not point at.
    func trashPath(_ path: String) {
        guard !trashing else { return }
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        trashing = true
        trashProgress = "Moving \(name)…"
        forgetTrashed([path])
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
                    Feedback.trashed()
                    db.prepare("DELETE FROM scan_entries WHERE parent = ? AND name = ?")
                        .run([.text(parent), .text(name)])
                }
                trashTick(db)
                self.refreshFromDatabase()
            }
        }
    }

    /// Disable a LaunchAgent: unload it (tolerating failure, this finding only fires for
    /// agents that are NOT currently running, so "already unloaded" is the normal case),
    /// then Trash its plist through the app's one deletion path. Recoverable from there,
    /// same as every other removal Performac performs.
    func disableAgent(_ path: String) {
        guard !trashing else { return }
        let name = (path as NSString).lastPathComponent
        trashing = true
        trashProgress = "Disabling \(name)…"
        let db = self.db
        Task.detached(priority: .userInitiated) { [weak self] in
            // The plist's own Label key, not its filename: the two are not guaranteed to
            // match, and launchctl only understands the label.
            let label = (NSDictionary(contentsOfFile: path)?["Label"] as? String)
                ?? (name as NSString).deletingPathExtension
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()

            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let r = Trash.moveToTrash([path], allowed: [path], db: db, now: now)
            let good = r.first?.ok == true
            let msg = r.first?.message ?? "unknown error"
            if good {
                // Drop it from the cached agent list too, so the card is gone on this
                // recompute rather than lingering until the next hourly LaunchAgents scan.
                let raw = getSetting(db, "loginAgents")?.objectVal?["agents"]?.arrayVal ?? []
                let kept = raw.filter { $0.objectVal?["plistPath"]?.stringVal != path }
                setSetting(db, "loginAgents", .object(["agents": .array(kept)]))
            }
            await refreshFindings(db, loadConfig(db), now, nil)
            await MainActor.run {
                guard let self else { return }
                self.trashing = false
                self.trashProgress = ""
                self.lastTrashSummary = good
                    ? "Disabled \(label) and moved its plist to the Trash."
                    : "Could not move it: \(msg)"
                self.refreshFromDatabase()
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

    // MARK: the cleaner, the only place the app removes anything

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
        let items = selected.filter(\.cleanable)
            .map { (name: $0.name, path: ($0.path as NSString).expandingTildeInPath) }
        runTrash(items, allowed: allowed)
    }

    /// Re-measure the paths just trashed and write fresh samples.
    ///
    /// This is what made trashing look slow. The move itself takes about 0.02 s. It is a
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

    /// Take the trashed paths off screen straight away.
    ///
    /// The move itself is a rename and finishes in milliseconds, but every list here is fed
    /// by a database read, and those only refresh at the end of the batch. That left rows
    /// sitting there looking untouched: a duplicate you had just removed was still offering
    /// to be removed. Anything that fails comes back on the refresh that follows.
    private func forgetTrashed(_ paths: Set<String>) {
        Self.afterTrash(paths: paths, browsePath: browsePath,
                        cacheEntries: &cacheEntries, diskEntries: &diskEntries,
                        dupGroups: &dupGroups)
    }

    /// Which rows a trash action removes from the screen, as a pure function of what was
    /// trashed. Pure so it can be checked without a database: it runs *before* the move
    /// finishes, so a row it drops by mistake is a file the user believes is gone.
    static func afterTrash(paths: Set<String>, browsePath: String,
                           cacheEntries: inout [CacheEntry],
                           diskEntries: inout [SizeEntry],
                           dupGroups: inout [DupGroup]) {
        cacheEntries.removeAll { paths.contains(($0.path as NSString).expandingTildeInPath) }
        // a contents-only entry survives its own emptying, so it drops to zero instead
        for i in cacheEntries.indices {
            let dir = (cacheEntries[i].path as NSString).expandingTildeInPath + "/"
            if paths.contains(where: { $0.hasPrefix(dir) }) { cacheEntries[i].bytes = 0 }
        }
        // a SizeEntry is keyed by name within the directory being browsed, so only paths
        // whose parent IS that directory may drop a row: otherwise trashing some unrelated
        // "Caches" folder would blank a row of the same name somewhere else entirely
        let hereNames = Set(paths
            .filter { ($0 as NSString).deletingLastPathComponent == browsePath }
            .map { ($0 as NSString).lastPathComponent })
        diskEntries.removeAll { hereNames.contains($0.name) }
        for i in dupGroups.indices { dupGroups[i].paths.removeAll { paths.contains($0) } }
        // one copy left is not a duplicate any more
        dupGroups.removeAll { $0.paths.count < 2 }
    }

    /// Shared by every bulk trash. Off the main actor, one item at a time so the progress
    /// line names what is actually being moved rather than spinning anonymously.
    private func runTrash(_ items: [(name: String, path: String)], allowed: Set<String>) {
        guard !trashing, !items.isEmpty else { return }
        trashing = true
        trashProgress = "Preparing…"
        forgetTrashed(Set(items.map(\.path)))
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
                if r.first?.ok == true {
                    ok += 1
                    // once for the batch: fifty caches moving should sound like one gesture
                    if ok == 1 { await MainActor.run { Feedback.trashed() } }
                } else {
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

    // MARK: disk scan (DiskView), streams progressively, Cancel cancels

    /// Held so Stop can let the walk unwind instead of tearing the stream down: that is what
    /// makes a stopped scan hand back what it already measured.
    private var scanCancel: CancelFlag?

    func startDiskScan() {
        guard !scanning else { return }
        scanTask?.cancel()
        let cancel = CancelFlag()
        scanCancel = cancel
        scanning = true
        scanFiles = 0
        scanBytes = 0
        scanElapsed = 0
        scanPath = ""
        scanStart = Date()
        let combined = scanRoot == Self.allDrives
        let roots = combined ? allDriveRoots : [(scanRoot as NSString).expandingTildeInPath]
        scanTask = Task { [weak self] in
            guard let self else { return }
            var summaries: [ScanSummary] = []
            // Drives are walked one after another rather than at once: each is its own device,
            // and eight concurrent stat threads per drive already saturates a USB bus. The
            // running totals carry across so progress does not restart at each drive.
            var carriedFiles = 0
            var carriedBytes: Int64 = 0
            for root in roots {
                if Task.isCancelled { return }
                if cancel.cancelled { break }
                // eight stat threads help flash and hurt rust; ask the device which it is
                var scanner = DiskScanner()
                scanner.concurrency = DiskScanner.concurrency(forVolume: root)
                for await event in scanner.scan(URL(fileURLWithPath: root), cancel: cancel) {
                    if Task.isCancelled { return }
                    switch event {
                    case .progress(let s):
                        self.scanFiles = carriedFiles + s.filesScanned
                        self.scanBytes = carriedBytes + s.bytes
                        self.scanElapsed = Date().timeIntervalSince(self.scanStart ?? Date())
                        self.scanPath = s.currentPath
                    case .finished(let sum):
                        summaries.append(sum)
                        carriedFiles += sum.files
                        carriedBytes += sum.bytes
                    }
                }
            }
            if Task.isCancelled { return }
            self.scanCancel = nil
            let written = self.buildTree(summaries)
            for sum in summaries where written.contains(sum.root) {
                if sum.partial { self.partialRoots.insert(sum.root) }
                else { self.partialRoots.remove(sum.root) }
            }
            let landing = combined ? Self.allDrives : (summaries.first?.root ?? roots[0])
            self.browsePath = landing
            self.diskEntries = self.childrenOf(landing)
            self.scanFiles = carriedFiles
            self.scanBytes = carriedBytes
            self.scanning = false
            // only the roots that actually produced a tree get a fresh timestamp; one that
            // came back empty kept its old rows and keeps its old time with them
            self.persistScan(written)
        }
    }

    /// Scanning every drive in one pass. "/" is a real path, so breadcrumbs, navigation, the
    /// trash allowlist and the scan_entries table all keep working with no special case:
    /// the only thing that needs handling is what its children are called.
    static let allDrives = "/"

    /// The drives an all-drives scan actually walks: every target except the sentinel itself.
    var allDriveRoots: [String] {
        scanTargets.filter { $0.path != Self.allDrives }
            .map { ($0.path as NSString).expandingTildeInPath }
    }

    /// A friendly name for a child of the all-drives root, whose stored name is a sub-path.
    static func driveLabel(forChild name: String) -> String {
        let full = "/" + name
        if full == NSHomeDirectory() { return "Home" }
        return (full as NSString).lastPathComponent
    }

    /// Home plus every mounted volume. Externals appear here the moment they are plugged in.
    var scanTargets: [(label: String, path: String)] {
        var out: [(String, String)] = [("Home", NSHomeDirectory())]
        for p in mountedVolumes { out.append(((p as NSString).lastPathComponent, p)) }
        // offered only when there is more than one thing to combine
        if out.count > 1 { out.insert(("All drives", Self.allDrives), at: 0) }
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

    /// Switching target shows what is already stored for it. Trees are kept per root, so
    /// picking the T7 after scanning Home browses the T7's last scan immediately: the Scan
    /// button is for refreshing it, not for seeing it.
    func setScanRoot(_ path: String) {
        scanRoot = path
        setSetting(db, "diskScanRoot", JSONValue.from(["path": path]))
        let landing = (path as NSString).expandingTildeInPath
        browsePath = landing
        backStack.removeAll()
        forwardStack.removeAll()
        diskEntries = childrenOf(landing)
    }

    /// Persist each scanned root, leaving every other root's tree alone.
    ///
    /// This used to be `DELETE FROM scan_entries`, one tree at a time, so scanning the T7
    /// threw away the scan of Home. Worse, when the T7 scan was returning nothing it deleted
    /// a good tree and inserted an empty one, turning a display bug into lost data. Now only
    /// the rows under the root being replaced are removed, and a root that came back empty is
    /// refused rather than allowed to overwrite what is already there.
    ///
    /// Returns the roots it actually wrote, so the caller only timestamps those.
    @discardableResult
    func buildTree(_ summaries: [ScanSummary]) -> [String] {
        db.prepare("BEGIN").run([])
        // substr rather than LIKE: a volume name may contain % or _, which LIKE would treat
        // as wildcards, and GLOB has the same problem with [ and *.
        let wipe = db.prepare("DELETE FROM scan_entries WHERE parent = ? OR substr(parent, 1, ?) = ?")
        let wipeRoot = db.prepare("DELETE FROM scan_entries WHERE parent = ? AND name = ?")
        let ins = db.prepare("INSERT INTO scan_entries(parent,name,items,bytes,is_dir,mtime,kind) VALUES(?,?,?,?,?,?,?)")
        let existing = db.prepare("SELECT count(*) c FROM scan_entries WHERE parent = ? OR substr(parent, 1, ?) = ?")
        var written: [String] = []

        for sum in summaries {
            let prefix = sum.root.hasSuffix("/") ? sum.root : sum.root + "/"
            let args: [SQLValue] = [.text(sum.root), .int(Int64(prefix.utf8.count)), .text(prefix)]
            let stored = existing.get(args)?["c"]?.intVal ?? 0
            // an empty result is far likelier to be a bug or a permissions wall than a truly
            // empty drive, so it must never replace a tree that already has content
            if sum.entries.isEmpty, stored > 0 { continue }
            // nor may a stopped scan overwrite a finished one: half a tree that looks whole
            // is worse than an old tree that is honestly labelled
            if sum.partial, stored > 0 { continue }

            wipe.run(args)
            for e in sum.entries {
                ins.run([.text(e.parent), .text(e.name),
                         .int(Int64(e.isDirectory ? e.files : 0)), .int(e.bytes),
                         .int(e.isDirectory ? 1 : 0), .int(e.mtime), .text(e.kind.rawValue)])
            }
            // One row per drive directly under "/", written for every scan and not only a
            // combined one: that is what lets "All drives" show Home and the T7 together
            // after they were scanned separately, with no rescan.
            let name = String(sum.root.dropFirst())
            if !name.isEmpty {
                wipeRoot.run([.text(Self.allDrives), .text(name)])
                if !sum.entries.isEmpty {
                    // The root itself is one of sum.entries (its dominant kind already rolled
                    // up the whole tree): reuse it rather than re-deriving from scratch.
                    let rootKind = sum.entries.first { $0.path == sum.root }?.kind ?? .other
                    ins.run([.text(Self.allDrives), .text(name), .int(Int64(sum.files)),
                             .int(sum.bytes), .int(1),
                             .int(sum.entries.map(\.mtime).max() ?? 0), .text(rootKind.rawValue)])
                }
            }
            written.append(sum.root)
        }
        db.prepare("COMMIT").run([])
        return written
    }

    /// Reads from the table, so a scan from last week browses exactly like a fresh one.
    func childrenOf(_ path: String) -> [SizeEntry] {
        readDB.prepare("SELECT name, items, bytes, is_dir, mtime, kind FROM scan_entries WHERE parent = ? ORDER BY bytes DESC")
            .all([.text(path)])
            .map { r in
                let isDir = (r["is_dir"]?.intVal ?? 1) == 1
                let name = r["name"]?.stringVal ?? ""
                let stored = r["kind"]?.stringVal ?? ""
                // Rows written before the `kind` migration carry ''. A file's kind is cheap
                // and exact to recompute from its extension, no rescan needed. A directory's
                // kind genuinely cannot be known without the subtree byte tally the old scan
                // never recorded, so it falls back to .other rather than inventing one.
                let kind: FileKind = stored.isEmpty
                    ? (isDir ? .other : FileKind.forFile(path: (path as NSString).appendingPathComponent(name)))
                    : (FileKind(rawValue: stored) ?? .other)
                return SizeEntry(
                    name: name,
                    items: Int(r["items"]?.intVal ?? 0),
                    bytes: r["bytes"]?.intVal ?? 0,
                    label: path == Self.allDrives ? Self.driveLabel(forChild: name) : nil,
                    symbol: isDir ? "folder.fill" : "doc.fill",
                    kind: kind,
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

    /// Processes actually seen recently, so ignoring one is a choice from a list rather than
    /// typing a name exactly right. Already-ignored ones are left out: offering to ignore
    /// something twice is a dead menu item.
    var ignorableProcesses: [String] {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 7 * 86_400_000
        let already = Set(loadConfig(readDB).hog.ignore)
        let rows = readDB.prepare("""
            SELECT name, MAX(cpu) peak FROM proc_samples WHERE ts >= ?
            GROUP BY name ORDER BY peak DESC LIMIT 40
            """).all([.int(cutoff)])
        return rows.compactMap { $0["name"]?.stringVal }
            .filter { !$0.isEmpty && !already.contains($0) }
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
        let rootName = rootPath == Self.allDrives
            ? "All drives" : (rootPath as NSString).lastPathComponent
        guard browsePath.hasPrefix(rootPath) else {
            return [(rootName, rootPath)]
        }
        var out: [(String, String)] = [(rootName, rootPath)]
        let rest = String(browsePath.dropFirst(rootPath.count)).split(separator: "/")
        var acc = rootPath
        for part in rest {
            acc = (acc as NSString).appendingPathComponent(String(part))
            out.append((String(part), acc))
        }
        return out
    }

    /// Stop, not abort. The walk is asked to unwind so it can hand back what it measured;
    /// on a spinning 2 TB drive, throwing that away means throwing away half an hour.
    func cancelDiskScan() {
        scanCancel?.cancel()
    }

    /// The Disk view is on screen. A scan only starts here when the user has opted in:
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
    /// blank screen, labelled as of its scan time, never presented as current.
    /// One timestamp per root. The tree itself is already in scan_entries; this is only the
    /// metadata that lets the view say how old what it is showing actually is.
    private func persistScan(_ roots: [String]) {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        for r in roots { scanTimes[r] = ts }
        setSetting(db, "diskScanTimes",
                   .object(scanTimes.mapValues { .number(Double($0)) }))
        setSetting(db, "diskScanPartial", .object(Dictionary(uniqueKeysWithValues:
                   partialRoots.map { ($0, JSONValue.bool(true)) })))
    }

    func loadPersistedScan() {
        autoRefreshScan = getSetting(db, "diskScanAutoRefresh")?.objectVal?["on"]?.boolVal ?? false
        if let saved = getSetting(db, "diskScanRoot")?.objectVal?["path"]?.stringVal { scanRoot = saved }
        if let m = getSetting(db, "diskViewMode")?.objectVal?["mode"]?.stringVal,
           let mode = DiskViewMode(rawValue: m) { diskViewMode = mode }
        else if getSetting(db, "diskViewMode") != nil { diskViewMode = .outline }   // retired mode
        if let r = getSetting(db, "rightPanelMode")?.objectVal?["mode"]?.stringVal,
           let rm = RightPanelMode(rawValue: r) { rightPanelMode = rm }
        if let partial = getSetting(db, "diskScanPartial")?.objectVal {
            partialRoots = Set(partial.filter { $0.value.boolVal == true }.keys)
        }
        if let times = getSetting(db, "diskScanTimes")?.objectVal {
            scanTimes = times.compactMapValues { $0.doubleVal.map(Int64.init) }
        } else if let o = getSetting(db, "lastDiskScan")?.objectVal,
                  let ts = o["ts"]?.doubleVal.map({ Int64($0) }),
                  let root = o["root"]?.stringVal {
            // carry the single old timestamp over to the per-root form
            scanTimes = [(root as NSString).expandingTildeInPath: ts]
        }
        guard let o = getSetting(db, "lastDiskScan")?.objectVal else { return }
        // The tree lives in scan_entries, so a stale scan is fully browsable on relaunch.
        let root = (o["root"]?.stringVal ?? scanRoot as String)
        browsePath = (root as NSString).expandingTildeInPath
        diskEntries = childrenOf(browsePath)
    }

    // MARK: Full Disk Access, real state, not a hardcoded pill

    static func checkFullDiskAccess() -> Bool {
        // ~/Library/Safari is FDA-protected; a plain read succeeds only with the grant.
        (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Safari")) != nil
    }
}

/// Optional one-time seed from the v1 Node app's database, for the single machine that ran it.
///
/// This used to be one developer's absolute home path compiled into every build: dead weight on
/// any other Mac, and their folder layout published in the binary. A fresh install wants an empty
/// database anyway, which is exactly what copyV1DatabaseIfNeeded produces when the source is
/// missing. Set PERFORMAC_V1_DB to migrate that history instead.
let V1_DATABASE_PATH = ProcessInfo.processInfo.environment["PERFORMAC_V1_DB"] ?? ""
