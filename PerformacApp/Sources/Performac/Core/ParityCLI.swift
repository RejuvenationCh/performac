// Core/ParityCLI.swift: `Performac parity <db> <nowMs>`: run the engine's
// refreshFindings against a database copy at a fixed clock and dump findings as JSON,
// normalized to v1's shapes (empty link_kind/link_target as null) for a clean diff.
import Foundation

enum ParityCLI {
    static func run(dbPath: String, now: Int64) async -> Int32 {
        let db = DB(path: dbPath)
        let cfg = loadConfig(db)
        await refreshFindings(db, cfg, now, nil)
        let rows = db.prepare("SELECT id, kind, severity, headline, why, detail, link_kind, link_target FROM findings ORDER BY id").all()
        let out = rows.map { row -> [String: Any] in
            func opt(_ k: String) -> Any? {
                guard let v = row[k], !v.isNull else { return nil }
                return v.stringVal.isEmpty ? nil : v.stringVal
            }
            return [
                "id": row["id"]?.stringVal ?? "",
                "kind": row["kind"]?.stringVal ?? "",
                "severity": row["severity"]?.stringVal ?? "",
                "headline": row["headline"]?.stringVal ?? "",
                "why": row["why"]?.stringVal ?? "",
                "detail": row["detail"]?.stringVal ?? "",
                "link_kind": opt("link_kind") as Any,
                "link_target": opt("link_target") as Any,
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        return 0
    }
}
