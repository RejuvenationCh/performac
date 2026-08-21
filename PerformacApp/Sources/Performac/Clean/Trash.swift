// Trash.swift — the ONLY deletion path in this application.
//
// FileManager.trashItem and nothing else. No unlink, no removeItem, no rm. Everything the
// app removes stays recoverable from the Trash, because the user has ~331 GB of
// irreplaceable footage and no backup of any kind: an unrecoverable delete bug here does
// not cost disk space, it costs work that cannot be reshot.
//
// Every call is checked against the caller-supplied allowlist first. That is defence in
// depth: the UI already offers only allowlisted rows, and this refuses anything else anyway.
import Foundation

enum Trash {
    struct Outcome: Sendable {
        var path: String
        var ok: Bool
        var message: String?
        var trashedTo: String?
    }

    /// `allowed` is the set of absolute paths the cleaner currently offers. A path must BE
    /// one of them — not merely live under one — so a crafted subpath cannot widen scope.
    /// Expand a folder to its children, for paths that can be emptied but not removed.
    static func childrenOf(_ path: String) -> [String] {
        let p = (path as NSString).expandingTildeInPath
        return ((try? FileManager.default.contentsOfDirectory(atPath: p)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { (p as NSString).appendingPathComponent($0) }
    }

    static func moveToTrash(_ paths: [String], allowed: Set<String>, db: DB?, now: Int64) -> [Outcome] {
        var out: [Outcome] = []
        let fm = FileManager.default
        for raw in paths {
            let path = (raw as NSString).expandingTildeInPath
            guard allowed.contains(path) else {
                out.append(.init(path: path, ok: false, message: "not on the cleaner's allowlist"))
                continue
            }
            guard fm.fileExists(atPath: path) else {
                out.append(.init(path: path, ok: false, message: "no longer exists"))
                continue
            }
            var resulting: NSURL?
            do {
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
                let dest = (resulting as URL?)?.path
                out.append(.init(path: path, ok: true, message: nil, trashedTo: dest))
                log(db, now, path, true, dest ?? "")
            } catch {
                let msg = error.localizedDescription
                out.append(.init(path: path, ok: false, message: msg))
                log(db, now, path, false, msg)
            }
        }
        return out
    }

    /// A record of everything the app has ever removed, so "what happened to that folder"
    /// always has an answer.
    private static func log(_ db: DB?, _ now: Int64, _ path: String, _ ok: Bool, _ detail: String) {
        guard let db else { return }
        db.prepare("INSERT INTO trash_log (ts, path, ok, detail) VALUES (?, ?, ?, ?)")
            .run([.int(now), .text(path), .int(ok ? 1 : 0), .text(detail)])
    }
}
