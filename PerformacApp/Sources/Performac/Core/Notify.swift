// Core/Notify.swift: a native notification, cooldown-gated. Cooldown persists in
// findings.last_notified so it survives restarts. Port of v1 notify.js.
//
// It used to run `osascript display notification`, which posts as Script Editor and which
// macOS may drop without a word. Posting goes through SamplerDeps.notify now, so checks
// record instead of posting and the app posts as itself.
import Foundation

/// title, subtitle, body. Throws when the notification was not posted.
typealias Poster = @Sendable (_ title: String, _ subtitle: String?, _ body: String) async throws -> Void

let NOTIFY_KINDS: Set<String> = ["drive", "thermal", "backup", "storage", "digest"]

@discardableResult
func maybeNotify(_ db: DB, _ finding: EngineFinding, _ cfg: Config, _ now: Int64,
                 _ post: Poster) async -> Bool {
    if cfg.notifyEnabled == false { return false }          // master switch (Settings)
    if finding.severity == "info" { return false }
    if !NOTIFY_KINDS.contains(finding.kind) { return false }
    if finding.kind == "storage" && finding.severity != "red" { return false }
    let row = db.prepare("SELECT last_notified FROM findings WHERE id = ?").get([.text(finding.id)])
    let cooldown = Int64(cfg.notifyCooldownHours) * 3_600_000
    if let row, let last = row["last_notified"], !last.isNull, now - last.intVal < cooldown {
        return false
    }
    do {
        try await post("Performac", finding.headline, finding.why)
    } catch {
        return false    // don't burn the cooldown on a failed fire
    }
    db.prepare("UPDATE findings SET last_notified = ? WHERE id = ?").run([.int(now), .text(finding.id)])
    return true
}
