// CleanPolicy.swift — what the cleaner is allowed to touch, and what it costs you.
//
// Default is DENY: an id with no policy here is never cleanable. Adding a path to the
// cleaner is a deliberate act, not something a new cache detector can do by accident.
import Foundation

struct CleanPolicy: Sendable {
    var cleanable: Bool
    /// true → "Safe to clean" (regenerates silently). false → "Check first" (regenerates
    /// loudly: re-renders, re-analysis, time you will notice).
    var safe: Bool
    /// What actually happens if you trash it. Shown on the row — never omitted.
    var consequence: String
}

enum Allowlist {
    private static let table: [String: CleanPolicy] = [
        // ---- Resolve ----
        "resolve-cache": .init(cleanable: true, safe: false,
            consequence: "Resolve re-renders previews on next open — a long timeline can take a while."),
        "resolve-proxy": .init(cleanable: true, safe: false,
            consequence: "Proxies must be regenerated before you can edit with them again."),
        // NOT cleanable. ~/Movies/.gallery holds .dpx stills — saved grades and reference
        // frames a colourist chose to keep. That is user work wearing a cache's clothing.
        "resolve-gallery": .init(cleanable: false, safe: false,
            consequence: "Saved stills and grades, not cache. Performac will never trash this."),

        // ---- Premiere / Adobe ----
        "premiere-media": .init(cleanable: true, safe: false,
            consequence: "Premiere rebuilds it when you next open a project; first playback is slower."),
        "premiere-db": .init(cleanable: true, safe: false,
            consequence: "The cache index. Premiere rebuilds it alongside the media cache."),
        "premiere-peaks": .init(cleanable: true, safe: true,
            consequence: "Audio waveforms, redrawn quickly on next open."),
        "premiere-analyzer": .init(cleanable: true, safe: true,
            consequence: "Media-intelligence analysis, regenerated on demand."),

        // ---- reclaimable, with the real cost stated ----
        "gen-homebrew": .init(cleanable: true, safe: true,
            consequence: "Downloaded installers Homebrew keeps after installing. Re-downloaded if ever needed."),
        "gen-logs": .init(cleanable: true, safe: true,
            consequence: "Application logs. Only useful when diagnosing a crash you are actively chasing."),
        "gen-xcode-devicesupport": .init(cleanable: true, safe: true,
            consequence: "Symbols for iOS versions you have debugged. Re-fetched next time you attach that device."),
        "gen-xcode-archives": .init(cleanable: true, safe: false,
            consequence: "Built archives of apps you shipped — the only copy of those exact builds."),
        "gen-simulators": .init(cleanable: true, safe: true,
            consequence: "Simulator caches, rebuilt on next launch."),
        // Not cleanable. If the phone is lost or wiped, this backup is the only copy.
        "gen-ios-backups": .init(cleanable: false, safe: false,
            consequence: "Your device backups — the only copy if a phone is lost. Remove them in Finder if you truly mean to."),

        // ---- Lightroom ----
        "lr-default": .init(cleanable: true, safe: false,
            consequence: "Lightroom rebuilds previews on demand; a large catalog takes a while."),
    ]

    /// Lightroom catalogs are discovered at runtime (lr-<slug>), so match the family too.
    static func policy(for target: CacheTarget) -> CleanPolicy {
        if let p = table[target.id] { return p }
        if target.id.hasPrefix("lr-") { return table["lr-default"]! }
        // Generic browser/dev caches carry their own label from the registry.
        switch target.safety {
        case "safe":
            return .init(cleanable: true, safe: true,
                         consequence: "Rebuilds itself on demand and signs you out of nothing.")
        case "check-first":
            return .init(cleanable: true, safe: false,
                         consequence: "Regenerated on next use, but the app may be slower first time.")
        default:
            // Unknown → not cleanable. Measuring is fine; trashing is not.
            return .init(cleanable: false, safe: false,
                         consequence: "Not on the cleaner's allowlist — Performac will not trash it.")
        }
    }
}
