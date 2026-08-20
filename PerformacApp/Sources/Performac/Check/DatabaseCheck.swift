// Check/DatabaseCheck.swift — schema + sweep + settings roundtrip checks (db.js port).
import Foundation

@MainActor
enum DatabaseCheck {
    static func run(_ c: CheckSuite) async {
        let db = DB(path: ":memory:")

        // schema: all v1 tables present
        let tables = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
            .all().compactMap { $0["name"]?.stringVal }
        for t in ["proc_samples", "disk_samples", "cache_samples", "events", "findings", "dup_groups", "settings"] {
            c.check("schema table \(t)", tables.contains(t), tables.joined(separator: ","))
        }

        // settings roundtrip
        setSetting(db, "hog", .object(["cpuPct": .number(95), "minMinutes": .number(30)]))
        let got = getSetting(db, "hog")
        c.eq("settings roundtrip: hog.cpuPct", got?.objectVal?["cpuPct"]?.doubleVal ?? 0, 95)
        c.check("settings roundtrip: missing key → nil", getSetting(db, "nope") == nil)
        // bare-string settings (v1 stores JSON.stringify of any value — the app crashed
        // here once; NSJSONSerialization refuses bare strings as top-level objects)
        setSetting(db, "premiere-sidebyside", .string("1"))
        c.eq("settings roundtrip: bare string", getSetting(db, "premiere-sidebyside")?.stringVal, "1")
        setSetting(db, "tickSec", .number(60))
        c.eq("settings roundtrip: bare number", getSetting(db, "tickSec")?.doubleVal, 60)

        // sweep: retention per table
        let now: Int64 = 1_756_000_000_000
        let insProc = db.prepare("INSERT INTO proc_samples(ts, pid, name, cpu, rss_mb) VALUES(?,?,?,?,?)")
        insProc.run([.int(now - 20 * 86_400_000), .int(1), .text("old"), .real(10), .int(100)])   // 20 d old → swept
        insProc.run([.int(now - 10 * 86_400_000), .int(2), .text("keep"), .real(10), .int(100)])  // 10 d → kept
        let insEvent = db.prepare("INSERT INTO events(ts, kind, key, detail) VALUES(?,?,?,?)")
        insEvent.run([.int(now - 100 * 86_400_000), .text("front_app"), .text("old"), .text("")])   // 100 d → swept
        insEvent.run([.int(now - 10 * 86_400_000), .text("front_app"), .text("keep"), .text("")])   // kept
        sweep(db, Config.defaults, now)
        let names = db.prepare("SELECT name FROM proc_samples").all().compactMap { $0["name"]?.stringVal }
        c.eq("sweep: proc rows older than retention deleted", names, ["keep"])
        let keys = db.prepare("SELECT key FROM events").all().compactMap { $0["key"]?.stringVal }
        c.eq("sweep: event rows older than retention deleted", keys, ["keep"])
    }
}
