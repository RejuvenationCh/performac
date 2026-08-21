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
        if let dest = ok.first?.trashedTo { try? FileManager.default.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil) }
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
