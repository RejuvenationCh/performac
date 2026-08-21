// Core/Paths.swift — D2 cache registry (runtime-detected) + the directory walker.
// Port of v1 paths.js: cacheTargets is pure (real config/prefs text and mdfind results
// arrive via inputs); measure walks without following symlinks.
import Foundation

// per-id metadata used by rules for card copy and link-outs
let CACHE_META: [String: (app: String, media: Bool, clearing: String)] = [
    "premiere-media":    ("Premiere", true, "Premiere: Settings → Media Cache → Delete."),
    "premiere-db":       ("Premiere", true, "Premiere: Settings → Media Cache → Delete."),
    "premiere-peaks":    ("Premiere", true, "Premiere: Settings → Media Cache → Delete."),
    "premiere-analyzer": ("Premiere", true, "Premiere: Settings → Media Cache → Delete."),
    "resolve-cache":     ("Resolve", true, "Resolve: Playback → Delete Render Cache, and Media Storage cleanup."),
    "resolve-gallery":   ("Resolve", true, "Resolve: Media Storage cleanup."),
    "resolve-proxy":     ("Resolve", true, "Resolve: delete proxies from the Media page."),
]

struct CacheTarget: Equatable, Sendable {
    var id: String
    var label: String
    var path: String
    var optional: Bool = false
    var note: String?          // "side-by-side"
    var safety: String?        // "safe" | "check-first" (generic entries)
    var measurement: MeasureResult?   // premeasured — no double walk
}

struct CacheTargetsInputs: Sendable {
    var home: String?
    var resolveCfg: String?
    var prefs: String?
    var lrcatPaths: [String]?
    var cacheDirs: [DiscoveredCacheDir]?

    struct DiscoveredCacheDir: Sendable, Equatable {
        var name: String
        var sizeMb: Int64
        var newestMtime: Int64?
        var fileCount: Int
    }
}

func cacheTargets(_ cfg: Config, inputs: CacheTargetsInputs = CacheTargetsInputs()) -> [CacheTarget] {
    let home = inputs.home ?? NSHomeDirectory()
    var targets: [CacheTarget] = []

    // Resolve — config.dat is plain key = value text
    let rc = parseResolveConfig(inputs.resolveCfg ?? "")
    let fsRoot = rc.fsRoot ?? home + "/Movies"
    let cacheDir = rc.cacheDir ?? "CacheClip"
    targets.append(CacheTarget(id: "resolve-cache", label: "Resolve render cache", path: fsRoot + "/" + cacheDir))
    targets.append(CacheTarget(id: "resolve-gallery", label: "Resolve gallery stills", path: fsRoot + "/.gallery"))
    targets.append(CacheTarget(id: "resolve-proxy", label: "Resolve proxies", path: fsRoot + "/ProxyMedia", optional: true))

    // Premiere — fixed Adobe/Common subdirs; prefs may override
    let prefs = inputs.prefs ?? ""
    let sideBySide = prefs.firstMatch(of: /<BE\.Prefs\.MediaCache\.FilesSideBySide>\s*(true|false)/)?.1 == "true"
    let override = prefs.firstMatch(of: /<BE\.Prefs\.MediaCache[^>]*>\s*(\/[^<\s]*)/)?.1
    let adobe = home + "/Library/Application Support/Adobe/Common"
    targets.append(CacheTarget(
        id: "premiere-media", label: "Premiere media cache",
        path: override.map(String.init) ?? adobe + "/Media Cache Files",
        note: sideBySide ? "side-by-side" : nil))
    targets.append(CacheTarget(id: "premiere-db", label: "Premiere cache database", path: adobe + "/Media Cache"))
    targets.append(CacheTarget(id: "premiere-peaks", label: "Premiere peak files", path: adobe + "/Peak Files"))
    targets.append(CacheTarget(id: "premiere-analyzer", label: "Premiere analyzer cache", path: adobe + "/Analyzer Cache Files"))

    // Lightroom — previews sit beside each catalog; mdfind discovers the catalogs
    var seen = Set<String>()
    var defaultCovered = false
    let lrHome = home + "/Pictures/Lightroom"
    for lrcat in inputs.lrcatPaths ?? [] {
        if lrcat.hasPrefix(lrHome) { defaultCovered = true }
        let dir = (lrcat as NSString).deletingLastPathComponent
        let base = ((lrcat as NSString).lastPathComponent as NSString).deletingPathExtension
        for (suffix, idSuffix) in [(" Previews.lrdata", "previews"), (" Smart Previews.lrdata", "smart"), (" Helper.lrdata", "helper")] {
            let p = dir + "/" + base + suffix
            if seen.contains(p) { continue }
            seen.insert(p)
            targets.append(CacheTarget(id: "lr-\(idSuffix)-\(slug("\(dir)/\(base)"))", label: "Lightroom \(base)", path: p))
        }
    }
    if !defaultCovered {
        targets.append(CacheTarget(id: "lr-default", label: "Lightroom Classic (default catalog)", path: lrHome))
    }

    // generic caches — safety labels mirror Purge's Safe to Clean / Check First
    let generic: [(String, String, String, String)] = [
        ("gen-xcode", "Xcode cache", home + "/Library/Caches/com.apple.dt.Xcode", "safe"),
        ("gen-deriveddata", "Xcode DerivedData", home + "/Library/Developer/Xcode/DerivedData", "safe"),
        ("gen-npm", "npm cache", home + "/.npm/_cacache", "safe"),
        ("gen-google", "Google Chrome cache", home + "/Library/Caches/Google", "check-first"),
        ("gen-brave", "Brave cache", home + "/Library/Caches/BraveSoftware", "check-first"),
        ("gen-zen", "Zen cache", home + "/Library/Caches/zen", "check-first"),
        // Space that piles up quietly and is genuinely re-downloadable or regenerated.
        ("gen-homebrew", "Homebrew downloads", home + "/Library/Caches/Homebrew", "safe"),
        ("gen-logs", "Application logs", home + "/Library/Logs", "safe"),
        ("gen-xcode-devicesupport", "Xcode device support", home + "/Library/Developer/Xcode/iOS DeviceSupport", "safe"),
        ("gen-xcode-archives", "Xcode archives", home + "/Library/Developer/Xcode/Archives", "check-first"),
        ("gen-simulators", "iOS Simulator runtimes", home + "/Library/Developer/CoreSimulator/Caches", "safe"),
        // iPhone/iPad backups. Large, and the only copy if the device is lost — never "safe".
        ("gen-ios-backups", "iPhone & iPad backups", home + "/Library/Application Support/MobileSync/Backup", "check-first"),
    ]
    for (id, label, path, safety) in generic {
        targets.append(CacheTarget(id: id, label: label, path: path, safety: safety))
    }
    for d in inputs.cacheDirs ?? [] {
        targets.append(CacheTarget(
            id: "gen-\(slug(d.name))",
            label: "\(d.name) cache",
            path: home + "/Library/Caches/" + d.name,
            safety: "safe",
            measurement: MeasureResult(sizeMb: Double(d.sizeMb), newestMtime: d.newestMtime, fileCount: d.fileCount)))
    }
    return targets
}

func slug(_ s: String) -> String {
    let stripped = s.lowercased().map { c -> Character in
        if c.isLetter || c.isNumber { return c }
        return "-"
    }
    var out = String(stripped)
    while out.hasPrefix("-") { out.removeFirst() }
    while out.hasSuffix("-") { out.removeLast() }
    return out
}

struct MeasureResult: Equatable, Sendable {
    var sizeMb: Double
    var newestMtime: Int64?
    var fileCount: Int
}

// walk a directory: sum sizes, newest mtime, file count.
// No symlink following; unreadable dirs count as 0/skip; missing dir → zeros.
func measure(_ dir: String) -> MeasureResult {
    var size: Int64 = 0
    var newest: Int64?
    var count = 0
    var dirs = [dir]
    while let d = dirs.popLast() {
        var entries: [URL] = []
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: d),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        } catch {
            continue   // unreadable dir counts as 0/skip
        }
        for e in entries {
            let vals = try? e.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            if vals?.isSymbolicLink == true { continue }
            if vals?.isDirectory == true { dirs.append(e.path); continue }
            if vals?.isRegularFile != true { continue }
            if let st = vals?.fileSize {
                size += Int64(st)
                count += 1
                if let mtime = vals?.contentModificationDate {
                    let ms = Int64((mtime.timeIntervalSince1970 * 1000).rounded())
                    if newest == nil || ms > newest! { newest = ms }
                }
            }
        }
    }
    return MeasureResult(sizeMb: Double(size) / 1_048_576, newestMtime: newest, fileCount: count)
}
