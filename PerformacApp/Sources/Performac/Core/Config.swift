// Core/Config.swift — DEFAULTS are the calibration knobs; settings-table rows override
// per top-level key. Port of v1 config.js — same values, same merge semantics.
import Foundation

// JSON value tree used for settings rows, validateSetting, and the loadConfig merge
// (mirrors the JS objects: numbers are Double, objects one-level-mergeable).
enum JSONValue: Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    var doubleVal: Double? { if case .number(let v) = self { return v }; return nil }
    var boolVal: Bool? { if case .bool(let v) = self { return v }; return nil }
    var stringVal: String? { if case .string(let v) = self { return v }; return nil }
    var arrayVal: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    var objectVal: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }

    static func from(_ any: Any?) -> JSONValue {
        guard let any else { return .null }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if let a = any as? [Any] { return .array(a.map(from)) }
        if let d = any as? [String: Any] { return .object(d.mapValues(from)) }
        return .null
    }
}

struct Hog: Codable, Sendable {
    var cpuPct: Double = 80
    var minMinutes: Int = 30
    var lookbackHours: Int = 24
    var ignore: [String] = ["kernel_task", "WindowServer", "launchd", "mds_stores", "backupd"]
}
struct Idle: Codable, Sendable {
    var rssMb: Int = 800
    var hours: Int = 12
}
struct Export: Codable, Sendable {
    var cpuPct: Double = 150
    var minMinutes: Int = 10
}
struct Thermal: Codable, Sendable {
    /// Degrees, not a pressure level. The die sensors are readable (see ThermalSensors), so
    /// the rule can say 87C instead of "elevated".
    var hotC: Double = 85
    var minHotMinutes: Int = 5
    var minElevatedMinutes: Int = 10
}
struct Drive: Codable, Sendable {
    var cycles24h: Int = 2
    var cycles7d: Int = 3
}
struct Backup: Codable, Sendable {
    var maxAgeDays: Int = 7
    var watchPaths: [WatchPath] = []
    var checkTimeMachine: Bool = true
    struct WatchPath: Codable, Sendable { var path: String; var maxAgeDays: Int }
}
struct Storage: Codable, Sendable {
    var fitDays: Int = 14
    var warnWeeksLeft: Int = 8
    var redWeeksLeft: Int = 3
}
struct CacheRules: Codable, Sendable {
    var amberGb: Double = 5
    var redGb: Double = 20
    var staleDays: Int = 21
}
/// Login-audit knobs. minHistoryDays exists because the headline claims evidence:
/// with a fresh database there is none, and the honest output is silence.
/// Below this the Trash is not worth a card.
struct TrashCfg: Codable, Sendable {
    var minBytes: Int64 = 1_000_000_000      // 1 GB
}

struct Login: Codable, Sendable {
    var minHistoryDays: Int = 7
}

struct Drift: Codable, Sendable {
    var paths: [String] = ["~/Downloads", "~/Desktop"]
    var minAgeDays: Int = 60
    var minMb: Double = 100
    var maxItems: Int = 8
}
struct Dup: Codable, Sendable {
    var minMb: Double = 100
}
struct Tier3: Codable, Sendable {
    var browserBloat: Bool = false
}
struct Browser: Codable, Sendable {
    var procs: [String] = ["Zen", "Google Chrome", "Brave Browser", "Safari", "Chromium"]
    var rssGb: Double = 4
    var minMinutes: Int = 60
}

struct Config: Codable, Sendable {
    var tickSec: Int = 30
    var diskTickSec: Int = 300
    var cacheTickSec: Int = 3600
    var procKeepTop: Int = 12
    var procMinCpu: Double = 3
    var procMinRssMb: Int = 300
    var retentionDays: Retention = Retention()
    var hog: Hog = Hog()
    var idle: Idle = Idle()
    var exportProcs: [String] = ["Adobe Premiere Pro", "Adobe Media Encoder", "PProHeadless",
                                 "Resolve", "Compressor", "Blackmagic Proxy Generator"]
    var export: Export = Export()
    var thermal: Thermal = Thermal()
    var drive: Drive = Drive()
    var backup: Backup = Backup()
    var storage: Storage = Storage()
    var cacheRules: CacheRules = CacheRules()
    var drift: Drift = Drift()
    var login: Login = Login()
    var trash: TrashCfg = TrashCfg()
    var dup: Dup = Dup()
    var notifyCooldownHours: Int = 24
    var weeklyDigestNotify: Bool = true
    var notifyEnabled: Bool = true
    var dupRoots: [String] = ["~"]
    var tier3: Tier3 = Tier3()
    var browser: Browser = Browser()

    struct Retention: Codable, Sendable {
        var proc: Int = 14
        var disk: Int = 180
        var cache: Int = 180
        var events: Int = 90
    }

    static let defaults = Config()
}

// validateSetting: value must match the template shape (numbers finite + positive,
// nested objects may carry a subset of template keys) — port of config.js, verbatim rules.
func validateSetting(_ value: JSONValue, _ template: JSONValue) -> Bool {
    switch template {
    case .number:
        guard let v = value.doubleVal else { return false }
        return v.isFinite && v > 0
    case .bool:
        return value.boolVal != nil
    case .string:
        return value.stringVal != nil
    case .array:
        return value.arrayVal != nil
    case .object(let tKeys):
        guard let v = value.objectVal else { return false }
        return v.allSatisfy { key, val in
            guard let t = tKeys[key] else { return false }   // unknown key rejected
            return validateSetting(val, t)
        }
    case .null:
        return false
    }
}

/// DEFAULTS encoded as a JSONValue — the template validateSetting checks against.
let defaultsTemplate: JSONValue = {
    let data = try! JSONEncoder().encode(Config.defaults)
    return JSONValue.from(try! JSONSerialization.jsonObject(with: data))
}()

// loadConfig: DEFAULTS deep-merged (one level) with settings rows — same semantics as
// v1 config.js: top-level keys replace; two objects merge one level.
func loadConfig(_ db: DB) -> Config {
    var merged = defaultsTemplate
    for (key, value) in allSettings(db) {
        if case .object(var a) = merged, let m = merged.objectVal, let cfg = m[key],
           case .object(let b) = value, case .object = cfg {
            // {...cfg, ...value} — the settings row wins; unset nested keys keep DEFAULTS
            var mergedValue = cfg.objectVal ?? [:]
            for (k, v) in b { mergedValue[k] = v }
            a[key] = .object(mergedValue)
            merged = .object(a)
        } else {
            var m = merged.objectVal ?? [:]
            m[key] = value
            merged = .object(m)
        }
    }
    let data = try! JSONSerialization.data(withJSONObject: merged.jsonObject)
    return try! JSONDecoder().decode(Config.self, from: data)
}
