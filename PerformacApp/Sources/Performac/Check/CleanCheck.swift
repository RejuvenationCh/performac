// CleanCheck.swift — the cleaner's safety properties, written to falsify.
import Foundation

enum CleanCheck {
    @MainActor static func run(_ c: CheckSuite) async {
        // default-deny: an unknown detector must not become cleanable by existing
        c.check("clean: unknown target is not cleanable",
                !Allowlist.policy(for: CacheTarget(id: "brand-new-thing", label: "x", path: "/tmp/x")).cleanable)
        // saved grades are user work, never cache
        c.check("clean: resolve gallery is never cleanable",
                !Allowlist.policy(for: CacheTarget(id: "resolve-gallery", label: "g", path: "/g")).cleanable)
        // the loud ones must not be labelled safe
        for id in ["resolve-cache", "premiere-media", "lr-default", "resolve-proxy"] {
            let p = Allowlist.policy(for: CacheTarget(id: id, label: id, path: "/x"))
            c.check("clean: \(id) is check-first", p.cleanable && !p.safe)
        }
        // runtime-discovered Lightroom catalogs inherit the family policy
        c.check("clean: lr-<slug> inherits check-first",
                Allowlist.policy(for: CacheTarget(id: "lr-abc123", label: "c", path: "/c")).cleanable)
        // every policy states a consequence — a row without one must not ship
        for id in ["resolve-cache", "premiere-peaks", "lr-default", "unknown-x"] {
            c.check("clean: \(id) states a consequence",
                    !Allowlist.policy(for: CacheTarget(id: id, label: id, path: "/x")).consequence.isEmpty)
        }

        // Trash refuses anything not on the allowlist, even if it exists.
        let tmp = NSTemporaryDirectory() + "performac-clean-check-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let outside = Trash.moveToTrash([tmp], allowed: [], db: nil, now: 0)
        c.check("clean: refuses a path not on the allowlist",
                outside.first?.ok == false && FileManager.default.fileExists(atPath: tmp))
        // a subpath of an allowed path is NOT itself allowed
        let sub = tmp + "/inner"
        try? FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let subOut = Trash.moveToTrash([sub], allowed: [tmp], db: nil, now: 0)
        c.check("clean: a subpath of an allowed path is refused",
                subOut.first?.ok == false && FileManager.default.fileExists(atPath: sub))
        // the allowed path itself goes to the Trash and is recoverable from there
        let ok = Trash.moveToTrash([tmp], allowed: [tmp], db: nil, now: 0)
        c.check("clean: allowlisted path is trashed", ok.first?.ok == true)
        c.check("clean: trashed item still exists in the Trash",
                ok.first?.trashedTo.map { FileManager.default.fileExists(atPath: $0) } == true)
        // the trashed fixture is left in place: it proves recoverability, and re-trashing
        // it would only add a second entry to the Bin
        // ---- sorting ----
        do {
            var st = SortState()
            c.check("sort: size opens largest first", st.key == .size && !st.ascending)
            st.toggle(.size)
            c.check("sort: clicking the active column flips it", st.ascending)
            st.toggle(.name)
            c.check("sort: a new column takes its own natural direction",
                    st.key == .name && st.ascending)      // names read A to Z
            st.toggle(.items)
            c.check("sort: counts open largest first", st.key == .items && !st.ascending)

            let rows = [
                SizeEntry(name: "beta", items: 3, bytes: 30, mtime: 300),
                SizeEntry(name: "Alpha", items: 10, bytes: 10, mtime: 100),
                SizeEntry(name: "gamma", items: 1, bytes: 20, mtime: 200),
            ]
            c.check("sort: by size descending",
                    rows.sorted(by: SortState(key: .size, ascending: false)).map(\.name) == ["beta", "gamma", "Alpha"])
            // case-insensitive and digit-aware, so "Alpha" leads and file10 follows file9
            c.check("sort: by name is case-insensitive",
                    rows.sorted(by: SortState(key: .name, ascending: true)).map(\.name) == ["Alpha", "beta", "gamma"])
            c.check("sort: by items ascending",
                    rows.sorted(by: SortState(key: .items, ascending: true)).map(\.name) == ["gamma", "beta", "Alpha"])
            c.check("sort: by date newest first",
                    rows.sorted(by: SortState(key: .date, ascending: false)).map(\.name) == ["beta", "gamma", "Alpha"])

            let caches = [
                CacheEntry(name: "big", bytes: 900, age: "1 day", ageDays: 1, safe: false, why: "", path: "/a"),
                CacheEntry(name: "old", bytes: 100, age: "40 days", ageDays: 40, safe: true, why: "", path: "/b"),
            ]
            c.check("sort: caches by age oldest first",
                    caches.sorted(by: SortState(key: .date, ascending: false)).map(\.name) == ["old", "big"])
            c.check("sort: caches by status puts safe first",
                    caches.sorted(by: SortState(key: .status, ascending: true)).map(\.name) == ["old", "big"])
        }

        // ---- cache origins ----
        // Every cleanable family must explain where its size comes from. "Cache" says
        // nothing about whether losing it costs a second or an afternoon.
        for id in ["gen-adobe", "resolve-cache", "premiere-media", "premiere-peaks",
                   "gen-deriveddata", "gen-homebrew", "gen-logs", "lr-default", "gen-zen"] {
            c.check("origin: \(id) explains itself", (CacheDetail.origin(forID: id) ?? "").count > 40)
        }
        c.check("origin: Adobe's names After Effects, which is where the size actually is",
                CacheDetail.origin(forID: "gen-adobe")?.contains("After Effects") == true)
        c.check("origin: Resolve's names how to clear it in-app",
                CacheDetail.origin(forID: "resolve-cache")?.contains("Delete Render Cache") == true)

        // a real directory is broken down largest-first, with counts
        let bdRoot = NSTemporaryDirectory() + "pc-breakdown-\(UUID().uuidString)"
        let big = bdRoot + "/big", small = bdRoot + "/small"
        for d in [big, small] { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        for i in 0..<12 { FileManager.default.createFile(atPath: "\(big)/f\(i).aecache", contents: Data(repeating: 0x41, count: 200_000)) }
        FileManager.default.createFile(atPath: "\(small)/one.bin", contents: Data(repeating: 0x42, count: 1000))
        let b = CacheDetail.inspect(bdRoot)
        c.check("breakdown: largest part first", b.parts.first?.name == "big")
        c.check("breakdown: counts the files", b.parts.first?.files == 12)
        c.check("breakdown: names the dominant extension", b.mainExtension == "aecache")
        c.check("breakdown: an empty path yields nothing", CacheDetail.inspect(bdRoot + "/nope").parts.isEmpty)

        // ---- Trash card ----
        let cfg = Config.defaults
        c.check("trash: silent below the threshold",
                Rules.trashHolding(500_000_000, 3, cfg, 0).isEmpty)
        c.check("trash: silent when empty even if bytes reported",
                Rules.trashHolding(5_000_000_000, 0, cfg, 0).isEmpty)
        let tf = Rules.trashHolding(18_000_000_000, 42, cfg, 0)
        c.check("trash: fires when holding real space", tf.count == 1)
        c.check("trash: headline names the size", tf.first?.headline.contains("GB") == true)
        // the app must never offer to empty it — the Trash is the undo for everything
        c.check("trash: only reveals, never empties", tf.first?.linkKind == "reveal")
        c.check("trash: detail says Performac will not empty it",
                tf.first?.detail.contains("never empties") == true)

        c.check("clean: missing path reports cleanly",
                Trash.moveToTrash(["/nope/nope"], allowed: ["/nope/nope"], db: nil, now: 0).first?.ok == false)
    }
}
