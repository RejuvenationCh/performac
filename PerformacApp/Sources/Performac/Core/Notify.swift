// Core/Notify.swift — osascript notification, cooldown-gated. Cooldown persists in
// findings.last_notified so it survives restarts. Port of v1 notify.js.
import Foundation

let NOTIFY_KINDS: Set<String> = ["drive", "thermal", "backup", "storage", "digest"]

@discardableResult
func maybeNotify(_ db: DB, _ finding: EngineFinding, _ cfg: Config, _ now: Int64,
                 _ exec: @Sendable (String, [String]) async throws -> String) async -> Bool {
    if cfg.notifyEnabled == false { return false }          // master switch (Settings)
    if finding.severity == "info" { return false }
    if !NOTIFY_KINDS.contains(finding.kind) { return false }
    if finding.kind == "storage" && finding.severity != "red" { return false }
    let row = db.prepare("SELECT last_notified FROM findings WHERE id = ?").get([.text(finding.id)])
    let cooldown = Int64(cfg.notifyCooldownHours) * 3_600_000
    if let row, let last = row["last_notified"], !last.isNull, now - last.intVal < cooldown {
        return false
    }
    func clean(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "") }
    let script = "display notification \"\(clean(finding.why))\" with title \"Performac\" subtitle \"\(clean(finding.headline))\""
    do {
        _ = try await exec("osascript", ["-e", script])     // argv array, never a shell string
    } catch {
        return false    // don't burn the cooldown on a failed fire
    }
    db.prepare("UPDATE findings SET last_notified = ? WHERE id = ?").run([.int(now), .text(finding.id)])
    return true
}
