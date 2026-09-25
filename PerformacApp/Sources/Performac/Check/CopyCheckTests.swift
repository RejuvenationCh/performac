// CopyCheckTests.swift: the single-copy detector, written to falsify.
// The dangerous failure is telling someone a folder is safe when it is not.
import Foundation

enum CopyCheckTests {
    @MainActor static func run(_ c: CheckSuite) async {
        let gb: Int64 = 1_073_741_824
        func listing(_ map: [String: [(String, Int64, Bool)]]) -> (String) -> [(name: String, bytes: Int64, isDir: Bool)] {
            { root in (map[root] ?? []).map { (name: $0.0, bytes: $0.1, isDir: $0.2) } }
        }

        let home = "/Users/me", t7 = "/Volumes/T7"
        let both = listing([
            home: [("Oweek", 40 * gb, true), ("Solo", 30 * gb, true)],
            t7:   [("Oweek", 40 * gb, true)],
        ])
        let r = CopyCheck.compare(roots: [home, t7], minBytes: 5 * gb, listing: both)
        let oweek = r.first { $0.path == home + "/Oweek" }
        let solo = r.first { $0.path == home + "/Solo" }
        c.check("copies: a folder present on both drives has a copy", oweek?.hasCopy == true)
        c.check("copies: the copy names where it was found", oweek?.copies == [t7])
        c.check("copies: a folder on one drive has none", solo?.hasCopy == false)

        // near-identical sizes still count: a copy made later is rarely byte-identical
        let nearly = listing([home: [("Oweek", 40 * gb, true)],
                              t7:   [("Oweek", Int64(Double(40 * gb) * 0.97), true)]])
        c.check("copies: a 3% size difference still counts as a copy",
                CopyCheck.compare(roots: [home, t7], minBytes: 5 * gb, listing: nearly)
                    .first { $0.path == home + "/Oweek" }?.hasCopy == true)
        // but a wildly different size does not: same name is not the same folder
        let notReally = listing([home: [("Oweek", 40 * gb, true)],
                                 t7:   [("Oweek", 2 * gb, true)]])
        c.check("copies: same name at a very different size is NOT a copy",
                CopyCheck.compare(roots: [home, t7], minBytes: 1 * gb, listing: notReally)
                    .first { $0.path == home + "/Oweek" }?.hasCopy == false)

        // files and small folders are never considered
        let noise = listing([home: [("tiny", 1 * gb, true), ("a-file", 90 * gb, false)]])
        let n = CopyCheck.compare(roots: [home], minBytes: 5 * gb, listing: noise)
        c.check("copies: small folders are ignored", !n.contains { $0.name == "tiny" })
        c.check("copies: files are not folders", !n.contains { $0.name == "a-file" })
        // caches and downloads are working state, not work
        let lib = listing([home: [("Library", 60 * gb, true), ("Downloads", 20 * gb, true)]])
        c.check("copies: Library and Downloads are excluded",
                CopyCheck.compare(roots: [home], minBytes: 5 * gb, listing: lib).isEmpty)

        // the card
        let alone = [CopyStatus(path: "/Users/me/Oweek", name: "Oweek", bytes: 40 * gb, copies: [])]
        let f = Rules.singleCopy(alone, Config.defaults, 0)
        c.check("copies: a lone folder produces a card", f.count == 1)
        c.check("copies: the card names the folder", f.first?.why.contains("Oweek") == true)
        c.check("copies: the card admits it only sees connected drives",
                f.first?.detail.contains("only sees drives that are connected") == true)
        c.check("copies: everything covered means no card",
                Rules.singleCopy([CopyStatus(path: "/x", name: "x", bytes: gb, copies: ["/Volumes/T7"])],
                                 Config.defaults, 0).isEmpty)
    }
}
