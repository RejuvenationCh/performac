// ViewModels.swift — UI-facing types and the sample data the views render until Phase 1
// wires the real engine. Shapes mirror v1's Finding/cache/dup rows so the swap is a
// data-source change, not a view rewrite.
import SwiftUI

enum Severity: String, Sendable {
    case info, good, amber, red
    var tint: Color { switch self { case .info: PC.accent; case .good: PC.green; case .amber: PC.amber; case .red: PC.red } }
    var soft: Color { switch self { case .info: PC.fill1; case .good: PC.greenSoft; case .amber: PC.amberSoft; case .red: PC.redSoft } }
    var symbol: String {
        switch self {
        case .info: "info.circle.fill"; case .good: "checkmark.seal.fill"
        case .amber: "exclamationmark.triangle.fill"; case .red: "exclamationmark.octagon.fill"
        }
    }
}

struct Finding: Identifiable, Sendable {
    let id = UUID()
    var severity: Severity
    var headline: String
    var why: String
    var link: String? = nil       // link-out label; at most one, never performs the fix
    /// Process this card is about, when it is safe to offer quitting it. Set by the store,
    /// never by the engine — the rules stay advisory and parity with v1 is unaffected.
    var quitTarget: String? = nil
}

struct SizeEntry: Identifiable, Sendable {
    let id = UUID()
    var name: String, items: Int, bytes: Int64
    var symbol = "folder.fill"
    var kind: FileKind = .other
}

enum FileKind: String, CaseIterable, Sendable {
    case video = "Video", image = "Image", cache = "Cache/App Data", document = "Document", other = "Other / System"
    var color: Color {
        switch self {
        case .video: Color(red: 0.72, green: 0.71, blue: 0.94)
        case .image: Color(red: 0.55, green: 0.80, blue: 0.66)
        case .cache: Color(red: 0.96, green: 0.83, blue: 0.58)
        case .document: Color(red: 0.62, green: 0.78, blue: 0.94)
        case .other: Color(red: 0.80, green: 0.82, blue: 0.86)
        }
    }
}

struct CacheEntry: Identifiable, Sendable {
    let id = UUID()
    var name: String, bytes: Int64, age: String
    var safe: Bool                // true → "Safe to clean", false → "Check first"
    var why: String
    var path: String
    /// Off the cleaner's allowlist → shown and measured, but never selectable or trashable.
    var cleanable = true
    var selected = false
}

struct DupGroup: Identifiable, Sendable {
    let id = UUID()
    var bytes: Int64, name: String, paths: [String]
}

// MARK: formatting — one place, so every figure in the app matches
enum Fmt {
    // DESIGN.md: decimal GB/MB, one decimal place, en_US regardless of system locale —
    // "29.8 GB", never "29,8 GB". ByteCountFormatter has no locale knob, so format directly.
    private static let en = Locale(identifier: "en_US")
    static func bytes(_ b: Int64) -> String {
        let gb = Double(b) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", locale: en, gb) }
        let mb = Double(b) / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", locale: en, mb) }
        return String(format: "%.0f KB", locale: en, Double(b) / 1_000)
    }
    static func count(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: sample data — replaced by the engine in Phase 1
@MainActor enum Sample {
    static let findings: [Finding] = [
        .init(severity: .amber, headline: "RobloxPlayer has averaged 99% CPU for 46 minutes",
              why: "That's sustained load, not a spike — quit it from Activity Monitor if you're not using it.",
              link: "Open Activity Monitor"),
        .init(severity: .red, headline: "External SSD disconnected and reconnected 2 times today",
              why: "A loose cable shows up as surprise unmount cycles — check it before your next shoot."),
        .init(severity: .info, headline: "Resolve's media cache is 27.7 GB",
              why: "Last written 15 days ago, still under your 21-day line — leave it."),
    ]
    static let disk: [SizeEntry] = [
        .init(name: "Data C (General)", items: 42_105, bytes: 355_395_000_000, kind: .video),
        .init(name: "Movies", items: 124, bytes: 31_997_000_000, kind: .video),
        .init(name: "Downloads", items: 892, bytes: 21_474_000_000, kind: .other),
        .init(name: "Library", items: 15_302, bytes: 19_756_000_000, kind: .cache),
        .init(name: "Desktop", items: 45, bytes: 6_012_000_000, kind: .document),
        .init(name: "Documents", items: 312, bytes: 4_617_000_000, kind: .document),
    ]
    static let caches: [CacheEntry] = [
        .init(name: "Resolve render cache", bytes: 31_997_000_000, age: "15 days ago", safe: false,
              why: "Clearing this forces Resolve to re-render previews.", path: "~/Movies/CacheClip"),
        .init(name: "Adobe Media Cache", bytes: 13_314_000_000, age: "2 days ago", safe: false,
              why: "In active use — Premiere will rebuild it on next open.",
              path: "~/Library/Application Support/Adobe/Common/Media Cache Files"),
        .init(name: "Analyzer Cache Files", bytes: 6_549_000_000, age: "41 days ago", safe: true,
              why: "Media-intelligence analysis, regenerated on demand.",
              path: "~/Library/Application Support/Adobe/Common/Analyzer Cache Files", selected: true),
        .init(name: "Browser caches", bytes: 3_435_000_000, age: "today", safe: true,
              why: "Rebuilds itself, signs you out of nothing.", path: "~/Library/Caches/zen", selected: true),
        .init(name: "Xcode DerivedData", bytes: 9_341_000_000, age: "60 days ago", safe: true,
              why: "Rebuilt on next build.", path: "~/Library/Developer/Xcode/DerivedData", selected: true),
    ]
    static let dups: [DupGroup] = [
        .init(bytes: 2_362_000_000, name: "TE Rally Games Final Export.mov",
              paths: ["~/Data C (General)/UC/Projects/Oweek/TE Rally Games/Export/", "~/Movies/Exports/"]),
        .init(bytes: 933_000_000, name: "Divisi Recap v2.mp4",
              paths: ["~/Downloads/", "~/Documents/Projects/Recap/", "~/Movies/"]),
        .init(bytes: 432_000_000, name: "Upacara Infinity Master.mov",
              paths: ["~/Movies/Raw/", "~/Documents/Upacara/"]),
    ]
}
