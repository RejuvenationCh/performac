// ViewModels.swift — UI-facing types the views render. Shapes mirror v1's Finding/cache/dup
// rows so the engine swap was a data-source change, not a view rewrite.
import SwiftUI

/// The engine only ever writes these three. `good` existed for years and was never produced,
/// so a card could never carry it and the severity ordering silently dropped it.
enum Severity: String, Sendable {
    case info, amber, red
    var tint: Color { switch self { case .info: PC.accent; case .amber: PC.amber; case .red: PC.red } }
    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .amber: "exclamationmark.triangle.fill"; case .red: "exclamationmark.octagon.fill"
        }
    }
}

/// A card's one link-out, carrying its destination rather than just a label.
///
/// The engine has always written `link_kind` *and* `link_target` (Rules.swift fills in real
/// folder paths), but the view only ever read the kind and rendered a dead button. Holding the
/// target in the case makes a link that cannot act unrepresentable: `reveal` with no path
/// fails to construct instead of drawing an accent-coloured no-op.
enum FindingLink: Sendable, Equatable {
    case reveal(String)
    case activityMonitor
    /// `open_purge` in the database. Purge is the app Performac's own cleaner replaces, so this
    /// goes to the Clean screen rather than launching something the user is removing.
    case clean
    /// `login_settings` in the database. There is no public API to remove another app's Login
    /// Items entry, so the only honest remedy is a deep link to the settings pane itself.
    case loginSettings
    /// `disable_agent` in the database, carrying the plist's path. Unlike every other case
    /// this one performs an action rather than merely navigating, so it must NOT be acted on
    /// from `openLink` — CoachCardView confirms it first, the way it already does for a quit.
    case disableAgent(String)

    var label: String {
        switch self {
        case .reveal: "Show in Finder"
        case .activityMonitor: "Open Activity Monitor"
        case .clean: "Open Clean"
        case .loginSettings: "Open Login Items"
        case .disableAgent: "Disable…"   // the ellipsis signals a confirmation follows
        }
    }

    init?(kind: String, target: String?) {
        switch kind {
        case "reveal":
            guard let target, !target.isEmpty else { return nil }
            self = .reveal(target)
        case "open_activity_monitor": self = .activityMonitor
        case "open_purge": self = .clean
        case "login_settings": self = .loginSettings
        case "disable_agent":
            guard let target, !target.isEmpty else { return nil }
            self = .disableAgent(target)
        default: return nil
        }
    }
}

struct Finding: Identifiable, Sendable {
    let id = UUID()
    var severity: Severity
    var headline: String
    var why: String
    var link: FindingLink? = nil  // at most one; `.disableAgent` is confirmed before it acts
    /// Process this card is about, when it is safe to offer quitting it. Set by the store,
    /// never by the engine — the rules stay advisory and parity with v1 is unaffected.
    var quitTarget: String? = nil
}

/// Which screen the window is showing. Lives here rather than in the view so a card's
/// link-out can navigate, and so the choice survives the window being closed and reopened.
enum Route: String, CaseIterable, Identifiable, Sendable {
    case overview, disk, clean, duplicates, settings
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .disk: "internaldrive"
        case .clean: "trash"
        case .duplicates: "doc.on.doc"
        case .settings: "gearshape"
        }
    }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The four screens the rail renders as its main list. Settings is pinned separately,
    /// below the spacer, the way Mail and Xcode place their settings affordance.
    static let primary: [Route] = [.overview, .disk, .clean, .duplicates]
}

struct SizeEntry: Identifiable, Sendable {
    let id = UUID()
    /// The navigation key: always the real path component under the parent, never prettified.
    var name: String, items: Int, bytes: Int64
    /// Shown instead of `name` when the two differ. Only the all-drives root uses this — its
    /// children are named "Users/you" and "Volumes/External SSD" so that appending them
    /// to "/" still produces a real path, while the row reads "Home" and "External SSD".
    var label: String? = nil
    var display: String { label ?? name }
    var symbol = "folder.fill"
    var kind: FileKind = .other
    /// Newest modification beneath this entry, epoch ms. 0 when unknown.
    var mtime: Int64 = 0
}

struct CacheEntry: Identifiable, Sendable {
    let id = UUID()
    var name: String, bytes: Int64, age: String
    /// Numeric age for sorting; the `age` string is for display.
    var ageDays: Double = 0
    var safe: Bool                // true → "Safe to clean", false → "Check first"
    var why: String
    var path: String
    /// Registry id, used to look up the origin explanation.
    var cacheID: String = ""
    /// Off the cleaner's allowlist → shown and measured, but never selectable or trashable.
    var cleanable = true
    var selected = false
}

/// One sample on the free-space chart. Carries its timestamp, because a chart you can hover
/// has to be able to say *when*, and bytes, because everything else on the screen is bytes —
/// `disk_samples.free_gb` is GiB (df's 1K blocks over 2^20), so 926.30 stored is the 994.6 GB
/// the Disk toolbar prints. Converting here keeps the chart and the stat tile above it from
/// disagreeing about the same disk.
struct TrendPoint: Sendable, Identifiable {
    var ts: Int64
    var freeBytes: Int64
    var id: Int64 { ts }
    var date: Date { Date(timeIntervalSince1970: Double(ts) / 1000) }

    init(ts: Int64, freeGiB: Double) {
        self.ts = ts
        self.freeBytes = Int64(freeGiB * 1_073_741_824)
    }
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
        // Every branch below falls through to KB once b is 0, printing "0 KB" — say what it is.
        if b <= 0 { return "0 bytes" }
        // TB matters here: without it a 2 TB drive read "2000.0 GB".
        let tb = Double(b) / 1_000_000_000_000
        if tb >= 1 { return String(format: "%.2f TB", locale: en, tb) }
        let gb = Double(b) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", locale: en, gb) }
        let mb = Double(b) / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", locale: en, mb) }
        return String(format: "%.0f KB", locale: en, Double(b) / 1_000)
    }

    /// Shared, not per call: allocating a NumberFormatter each time measured ~29x slower
    /// (51.5 ms vs 1.8 ms per 5000 calls), and this runs once per row per redraw.
    private static let counter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        return f
    }()
    static func count(_ n: Int) -> String {
        counter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

/// How the Disk view draws the current folder. Outline is the default: it is the only mode
/// that shows depth without losing your place.
/// The left pane is textual; the visual shapes (treemap, bubbles) live in the right panel.
/// Showing bubbles in both at once was redundant, so it is not offered here.
enum DiskViewMode: String, CaseIterable, Sendable {
    case outline, list, compact
    var label: String {
        switch self {
        case .outline: "Outline"; case .list: "List"; case .compact: "Compact"
        }
    }
    var symbol: String {
        switch self {
        case .outline: "list.bullet.indent"; case .list: "list.bullet"
        case .compact: "rectangle.compress.vertical"
        }
    }
}


/// What the right-hand panel draws: proportional rectangles or Space Lens circles.
enum RightPanelMode: String, CaseIterable, Sendable {
    case treemap, bubbles
    var label: String { self == .treemap ? "Treemap" : "Bubbles" }
    var symbol: String { self == .treemap ? "square.grid.2x2" : "circle.circle" }
}


/// Sort orders for the disk browser and the cleaner. Each view uses the subset it has
/// columns for, so the enum stays one thing rather than two near-identical ones.
enum SortKey: String, Sendable {
    case name, items, size, date, status
    /// Sizes and counts open largest-first; names and dates open the way you read them.
    var defaultAscending: Bool {
        switch self {
        case .name, .status: true
        case .items, .size, .date: false
        }
    }
}

struct SortState: Sendable, Equatable {
    var key: SortKey = .size
    var ascending: Bool = false

    /// Clicking the active column flips it; clicking another switches to that column's
    /// natural direction rather than inheriting the previous one.
    mutating func toggle(_ k: SortKey) {
        if key == k { ascending.toggle() } else { key = k; ascending = k.defaultAscending }
    }
}

extension Array where Element == SizeEntry {
    func sorted(by s: SortState) -> [SizeEntry] {
        let asc = s.ascending
        switch s.key {
        case .name:  return sorted { asc ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                                         : $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .items: return sorted { asc ? $0.items < $1.items : $0.items > $1.items }
        case .date:  return sorted { asc ? $0.mtime < $1.mtime : $0.mtime > $1.mtime }
        default:     return sorted { asc ? $0.bytes < $1.bytes : $0.bytes > $1.bytes }
        }
    }
}

extension Array where Element == CacheEntry {
    func sorted(by s: SortState) -> [CacheEntry] {
        let asc = s.ascending
        switch s.key {
        case .name:   return sorted { asc ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                                          : $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .date:   return sorted { asc ? $0.ageDays < $1.ageDays : $0.ageDays > $1.ageDays }
        // safe-to-clean first when ascending: the ones you can act on without thinking
        case .status: return sorted { asc ? ($0.safe ? 1 : 0) > ($1.safe ? 1 : 0)
                                          : ($0.safe ? 1 : 0) < ($1.safe ? 1 : 0) }
        default:      return sorted { asc ? $0.bytes < $1.bytes : $0.bytes > $1.bytes }
        }
    }
}
