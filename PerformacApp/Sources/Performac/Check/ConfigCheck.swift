// Check/ConfigCheck.swift: ports of v1 test/config.test.js.
import Foundation

@MainActor
enum ConfigCheck {
    static func run(_ c: CheckSuite) async {
        // validateSetting: types against DEFAULTS shape
        c.check("validateSetting(95, 30)", validateSetting(.number(95), .number(30)))
        c.check("validateSetting('95', 30) rejected", !validateSetting(.string("95"), .number(30)))
        c.check("validateSetting(-5, 30) rejected", !validateSetting(.number(-5), .number(30)))
        c.check("validateSetting(NaN, 30) rejected", !validateSetting(.number(.nan), .number(30)))
        c.check("validateSetting(true, false)", validateSetting(.bool(true), .bool(false)))
        c.check("validateSetting(1, true) rejected", !validateSetting(.number(1), .bool(true)))
        c.check("validateSetting({cpuPct:95}, hog)", validateSetting(.object(["cpuPct": .number(95)]), defaultsTemplate.objectVal!["hog"]!))
        c.check("validateSetting unknown nested key rejected",
                !validateSetting(.object(["cpuPct": .number(95), "bogus": .number(1)]), defaultsTemplate.objectVal!["hog"]!))
        c.check("validateSetting wrong nested type rejected",
                !validateSetting(.object(["cpuPct": .string("95")]), defaultsTemplate.objectVal!["hog"]!))
        c.check("validateSetting({browserBloat:true}, tier3)", validateSetting(.object(["browserBloat": .bool(true)]), defaultsTemplate.objectVal!["tier3"]!))
        c.check("validateSetting(['~/Desktop'], drift.paths)",
                validateSetting(.array([.string("~/Desktop")]), defaultsTemplate.objectVal!["drift"]!.objectVal!["paths"]!))
        c.check("validateSetting('x', drift.paths) rejected",
                !validateSetting(.string("x"), defaultsTemplate.objectVal!["drift"]!.objectVal!["paths"]!))

        // loadConfig: PUT a threshold → merged config reflects it (persists via settings rows)
        let db = DB(path: ":memory:")
        setSetting(db, "hog", .object(["cpuPct": .number(95)]))

        setSetting(db, "tier3", .object(["browserBloat": .bool(true)]))

        setSetting(db, "tickSec", .number(60))

        let cfg = loadConfig(db)
        c.eq("loadConfig: hog.cpuPct", cfg.hog.cpuPct, 95)
        c.eq("loadConfig: unset nested keys keep DEFAULTS", cfg.hog.minMinutes, 30)
        c.check("loadConfig: tier3.browserBloat on", cfg.tier3.browserBloat)
        c.eq("loadConfig: tickSec", cfg.tickSec, 60)
        c.eq("loadConfig: fresh load sees same values", loadConfig(db).hog.cpuPct, 95)
    }
}
