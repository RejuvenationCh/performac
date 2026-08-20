// Core/Collectors.swift — pure string→object parsers for every CLI output.
// Port of v1 collectors.js: bad input → nil/[]/empty state; never throws.
import Foundation

struct PsRow: Equatable, Sendable {
    var pid: Int64
    var cpu: Double
    var rssMb: Int64
    var name: String
}

func parsePs(_ text: String?) -> [PsRow] {
    var rows: [PsRow] = []
    for line in (text ?? "").split(separator: "\n") {
        let s = String(line)
        guard let m = s.wholeMatch(of: /^\s*(\d+)\s+([\d.]+)\s+(\d+)\s+(.+?)\s*$/) else { continue }
        rows.append(PsRow(
            pid: Int64(m.1) ?? 0,
            cpu: Double(m.2) ?? 0,
            rssMb: Int64(((Double(m.3) ?? 0) / 1024).rounded()),
            name: m.4.trimmingCharacters(in: .whitespaces)))
    }
    return rows
}

struct DfRow: Equatable, Sendable {
    var mount: String
    var freeGb: Double
    var totalGb: Double
}

func parseDf(_ text: String?) -> [DfRow] {
    var rows: [DfRow] = []
    for line in (text ?? "").split(separator: "\n") {
        let f = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if f.count < 9 || !f[0].hasPrefix("/dev/disk") { continue }
        rows.append(DfRow(
            mount: f[8...].joined(separator: " "),
            freeGb: (Double(f[3]) ?? 0) / 1_048_576,
            totalGb: (Double(f[1]) ?? 0) / 1_048_576))
    }
    return rows
}

func parseFrontAppName(_ text: String?) -> String? {
    guard let m = (text ?? "").wholeMatch(of: /"LSDisplayName"\s*=\s*"([^"]*)"/) else { return nil }
    return String(m.1)
}

struct ThermState: Equatable, Sendable {
    var available: Bool
    var cpuSpeedLimit: Int64?
}

func parseTherm(_ text: String?) -> ThermState {
    if let m = (text ?? "").wholeMatch(of: /CPU_Speed_Limit\s*=\s*(\d+)/) {
        return ThermState(available: true, cpuSpeedLimit: Int64(m.1))
    }
    return ThermState(available: false, cpuSpeedLimit: nil)
}

func parseThermlogLine(_ line: String?) -> Int64? {
    guard let m = (line ?? "").firstMatch(of: /Thermal Warning Level\s*=\s*(\d+)/) else { return nil }
    return Int64(m.1)
}

struct BatteryState: Equatable, Sendable {
    var cycleCount: Int64
    var designCap: Int64
    var nominalCap: Int64
    var healthPct: Double
}

func parseBattery(_ text: String?) -> BatteryState? {
    func g(_ k: String) -> Int64? {
        let re = try! NSRegularExpression(pattern: "\"" + k + "\"\\s*=\\s*(\\d+)")
        let str = text ?? ""
        guard let m = re.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
              m.range(at: 1).location != NSNotFound else { return nil }
        return Int64((str as NSString).substring(with: m.range(at: 1)))
    }
    guard let nominal = g("NominalChargeCapacity"),
          let design = g("DesignCapacity"),
          let cycles = g("CycleCount") else { return nil }
    let pct = (Double(nominal) / Double(design) * 1000).rounded() / 10
    return BatteryState(cycleCount: cycles, designCap: design, nominalCap: nominal, healthPct: pct)
}

struct TmDestinations: Equatable, Sendable {
    var configured: Bool
    var names: [String]
}

func parseTmDestinations(_ text: String?) -> TmDestinations {
    var names: [String] = []
    for line in (text ?? "").split(separator: "\n") {
        if let m = line.wholeMatch(of: /^Name\s*:\s*(.+)$/) { names.append(String(m.1).trimmingCharacters(in: .whitespaces)) }
    }
    return TmDestinations(configured: !names.isEmpty, names: names)
}

struct TmLatest: Equatable, Sendable {
    var backupISO: String
}

func parseTmLatest(_ text: String?) -> TmLatest? {
    guard let m = (text ?? "").firstMatch(of: /(\d{4})-(\d{2})-(\d{2})-(\d{6})\.backup/) else { return nil }
    let t = m.4
    let iso = "\(m.1)-\(m.2)-\(m.3)T\(t.prefix(2)):\(t.dropFirst(2).prefix(2)):\(t.dropFirst(4).prefix(2))"
    return TmLatest(backupISO: iso)
}

struct ResolveConfig: Equatable, Sendable {
    var fsRoot: String?
    var cacheDir: String?
}

func parseResolveConfig(_ text: String?) -> ResolveConfig {
    let s = text ?? ""
    let root = s.firstMatch(of: /(?m)^Site\.\d+\.FS\.1\.Root\s*=\s*(.+)$/)
    let dir = s.firstMatch(of: /(?m)^RenderCaching\.CacheDir\s*=\s*(.+)$/)
    return ResolveConfig(
        fsRoot: root.map { String($0.1).trimmingCharacters(in: .whitespaces) },
        cacheDir: dir.map { String($0.1).trimmingCharacters(in: .whitespaces) })
}

// real `diskutil activity` lines carry the literal string DAVolumeName = '<null>' for unnamed
// disks (disk/container/scheme events) — that is NOT a name, return nil so no event is written.
// ts comes from the line's own Time=YYYYMMDD-HH:MM:SS (local), nil when absent.
struct DiskActivity: Equatable, Sendable {
    var kind: String   // appeared | disappeared
    var volume: String
    var ts: Int64?
}

func parseDiskutilActivity(_ line: String?) -> DiskActivity? {
    let s = line ?? ""
    guard let m = s.firstMatch(of: /\*\*\*Disk(Appeared|Disappeared).*DAVolumeName = '([^']*)'/) else { return nil }
    let name = String(m.2)
    if name.isEmpty || name == "<null>" { return nil }
    var ts: Int64?
    if let t = s.firstMatch(of: /Time=(\d{4})(\d{2})(\d{2})-(\d{2}):(\d{2}):(\d{2})/) {
        var comps = DateComponents()
        comps.year = Int(t.1); comps.month = Int(t.2); comps.day = Int(t.3)
        comps.hour = Int(t.4); comps.minute = Int(t.5); comps.second = Int(t.6)
        if let date = Calendar.current.date(from: comps) { ts = Int64(date.timeIntervalSince1970 * 1000) }
    }
    return DiskActivity(kind: String(m.1).lowercased(), volume: name, ts: ts)
}

// `diskutil info -plist <vol>` — booleans render as <true/>/<false/> tags
struct DiskInfo: Equatable, Sendable {
    var `internal`: Bool
    var ejectable: Bool
}

func parseDiskutilInfo(_ text: String?) -> DiskInfo? {
    let s = text ?? ""
    func val(_ k: String) -> Bool? {
        let re = try! NSRegularExpression(pattern: "<key>" + k + "</key>\\s*<(true|false)/>")
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.range(at: 1).location != NSNotFound else { return nil }
        return (s as NSString).substring(with: m.range(at: 1)) == "true"
    }
    let internalV = val("Internal")
    let ejectable = val("Ejectable")
    if internalV == nil && ejectable == nil { return nil }
    return DiskInfo(internal: internalV ?? false, ejectable: ejectable ?? false)
}

// `pmset -g batt -o` → "Now drawing from 'AC Power'" / "'Battery Power'"
func parsePower(_ text: String?) -> String? {
    guard let m = (text ?? "").wholeMatch(of: /Now drawing from '([^']+)'/) else { return nil }
    return String(m.1)
}

func parseLoginItems(_ text: String?) -> [String] {
    (text ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}
