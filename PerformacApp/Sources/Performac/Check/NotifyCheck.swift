// Check/NotifyCheck.swift, ports of v1 test/notify.test.js: cooldown logic,
// kind allowlist, argv (no shell), quote stripping.
import Foundation

@MainActor
enum NotifyCheck {
    static func run(_ c: CheckSuite) async {
        var cfg = Config.defaults
        cfg.notifyCooldownHours = 24

        func insertFinding(_ db: DB, id: String = "f1", kind: String = "backup", severity: String = "red") -> EngineFinding {
            let f = EngineFinding(id: id, kind: kind, severity: severity,
                                  headline: "Head \"quoted\"", why: "Why \"quoted\"",
                                  detail: "", linkKind: nil, linkTarget: nil)
            db.prepare("INSERT INTO findings(id, kind, severity, headline, why, detail, link_kind, link_target, first_seen, updated, last_notified) VALUES(?,?,?,?,?,?,?,?,?,?,?)")
                .run([.text(f.id), .text(f.kind), .text(f.severity), .text(f.headline), .text(f.why),
                      .text(f.detail), .null, .null, .int(0), .int(0), .null])
            return f
        }

        final class Calls: @unchecked Sendable { var calls: [[String]] = [] }
        func fakeExec() -> (calls: Calls, exec: @Sendable (String, [String]) async throws -> String) {
            let box = Calls()
            return (box, { @Sendable file, args in
                box.calls.append([file] + args)
                return ""
            })
        }

        // red finding fires osascript once with argv array and stripped quotes
        do {
            let db = DB(path: ":memory:")
            let (calls, exec) = fakeExec()
            let f = insertFinding(db)
            let fired = await maybeNotify(db, f, cfg, 1000, exec)
            c.check("red fires", fired)
            c.check("one call", calls.calls.count == 1)
            c.eq("osascript argv", calls.calls[0],
                 ["osascript", "-e",
                  "display notification \"Why quoted\" with title \"Performac\" subtitle \"Head quoted\""])
        }
        // cooldown 24h
        do {
            let db = DB(path: ":memory:")
            let (calls, exec) = fakeExec()
            let f = insertFinding(db)
            _ = await maybeNotify(db, f, cfg, 1000, exec)
            _ = await maybeNotify(db, f, cfg, 1000 + 3_600_000, exec)     // +1h → still cooling
            c.eq("cooldown: second call skipped", calls.calls.count, 1)
            _ = await maybeNotify(db, f, cfg, 1000 + 25 * 3_600_000, exec) // +25h → fires
            c.eq("cooldown: fires after window", calls.calls.count, 2)
            let row = db.prepare("SELECT last_notified FROM findings WHERE id = ?").get([.text("f1")])
            c.eq("cooldown: last_notified updated", row?["last_notified"]?.intVal, 1000 + 25 * 3_600_000)
        }
        // info severity never notifies
        do {
            let db = DB(path: ":memory:")
            let (calls, exec) = fakeExec()
            _ = insertFinding(db, id: "f2", severity: "info")
            let fired = await maybeNotify(db, insertFinding(db, id: "f3", severity: "info"), cfg, 1000, exec)
            c.check("info never notifies", !fired && calls.calls.count == 0)
        }
        // kind allowlist
        for kind in ["drive", "thermal", "backup", "digest"] {
            let db = DB(path: ":memory:")
            let (calls, exec) = fakeExec()
            _ = await maybeNotify(db, insertFinding(db, id: kind, kind: kind, severity: "amber"), cfg, 1000, exec)
            c.check("amber \(kind) notifies", calls.calls.count == 1, "calls=\(calls.calls.count)")
        }
        do {
            let db = DB(path: ":memory:")
            let (calls, exec) = fakeExec()
            _ = await maybeNotify(db, insertFinding(db, id: "s1", kind: "storage", severity: "amber"), cfg, 1000, exec)
            c.check("amber storage must not notify", calls.calls.count == 0)
            _ = await maybeNotify(db, insertFinding(db, id: "s2", kind: "storage", severity: "red"), cfg, 1000, exec)
            c.check("red storage notifies", calls.calls.count == 1)
        }
        do {
            let db = DB(path: ":memory:")
            let (calls, exec) = fakeExec()
            _ = await maybeNotify(db, insertFinding(db, id: "c1", kind: "cache", severity: "red"), cfg, 1000, exec)
            c.check("red cache must not notify", calls.calls.count == 0)
        }
        // failed fire does not burn the cooldown
        do {
            let db = DB(path: ":memory:")
            final class Flag: @unchecked Sendable { var value = true }
            let fail = Flag()
            let f = insertFinding(db)
            _ = await maybeNotify(db, f, cfg, 1000, { @Sendable _, _ in
                if fail.value { throw NSError(domain: "fake", code: 1) }
                return ""
            })
            fail.value = false
            let fired = await maybeNotify(db, f, cfg, 1000, { @Sendable _, _ in "" })
            c.check("failed fire does not burn cooldown", fired)
        }
    }
}
