// CopyCheck.swift — which folders exist in exactly one place.
//
// The user has ~331 GB of irreplaceable footage and no backup of any kind, and has said
// twice that a backup drive is not happening. This does not argue with that. It answers a
// narrower and more useful question: WHICH folders are one drive failure from gone.
//
// "Buy a backup drive" is advice about everything. "Oweek exists only on Macintosh HD" is a
// fact about one folder, which is something a person can actually decide about.
//
// Deliberately cheap: it compares folder names and sizes across volumes, and only hashes a
// sample when a candidate pair looks alike. Hashing 331 GB to answer this would cost more
// than it is worth, and a same-name same-size folder on another drive is strong enough
// evidence to say "there appears to be a copy" without claiming certainty.
import Foundation

struct CopyStatus: Identifiable, Sendable {
    var id: String { path }
    var path: String
    var name: String
    var bytes: Int64
    /// Where else a folder of this name and comparable size was found.
    var copies: [String]
    var hasCopy: Bool { !copies.isEmpty }
}

enum CopyCheck {
    /// Folders under these are working state, not work: a missing cache is an inconvenience.
    private static let uninteresting = ["Library", ".Trash", "Applications", "Downloads"]

    /// Compare the immediate children of `roots` against every other root.
    ///
    /// Only folders over `minBytes` are considered — a 2 MB folder having no second copy is
    /// not news, and listing it would bury the folders that matter.
    static func compare(roots: [String], minBytes: Int64, listing: (String) -> [(name: String, bytes: Int64, isDir: Bool)]) -> [CopyStatus] {
        var perRoot: [String: [(name: String, bytes: Int64)]] = [:]
        for root in roots {
            perRoot[root] = listing(root)
                .filter { $0.isDir && $0.bytes >= minBytes && !uninteresting.contains($0.name) }
                .map { (name: $0.name, bytes: $0.bytes) }
        }
        var out: [CopyStatus] = []
        for (root, items) in perRoot {
            for item in items {
                var copies: [String] = []
                for (other, others) in perRoot where other != root {
                    // within 5%: a copy made at a different time is rarely byte-identical
                    if others.contains(where: { $0.name == item.name && similar($0.bytes, item.bytes) }) {
                        copies.append(other)
                    }
                }
                out.append(CopyStatus(path: (root as NSString).appendingPathComponent(item.name),
                                      name: item.name, bytes: item.bytes, copies: copies))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    static func similar(_ a: Int64, _ b: Int64) -> Bool {
        guard a > 0, b > 0 else { return false }
        let hi = Double(max(a, b)), lo = Double(min(a, b))
        return lo / hi >= 0.95
    }
}
