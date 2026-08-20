// Check/CollectorsCheck.swift — ports of v1 test/collectors.test.js.
// Fixtures are the real captured outputs, brought across verbatim.
import Foundation

@MainActor
enum CollectorsCheck {
    static let PS = """
      PID  %CPU    RSS COMM
      693  98.2  73072 RobloxPlayer
      172  47.5 171392 WindowServer
    54509  28.1 615328 Claude Helper (Renderer)
    """

    static let DF = """
    Filesystem     1024-blocks      Used Available Capacity iused     ifree %iused  Mounted on
    /dev/disk3s1s1   971298980  15833916  64775288    20%  458734 647752880    0%   /
    devfs                  199       199         0   100%     690         0  100%   /dev
    """

    static let FRONT = "\"LSDisplayName\"=\"Zen\""

    static let THERM_EMPTY = """
    Note: No thermal warning level has been recorded
    Note: No performance warning level has been recorded
    Note: No CPU power status has been recorded
    """

    static let THERM_LIMIT = "CPU_Speed_Limit \t= 70"

    static let THERMLOG = "2026-08-20 13:11:08 +0700 Thermal Warning Level = 1"

    static let BATT = """
          "NominalChargeCapacity" = 6024
          "DesignCapacity" = 6249
          "CycleCount" = 78
    """

    static let TM_NONE = "tmutil: No destinations configured."

    static let TM_ONE = """
    ====================================================
    Name          : T7 Backup
    Kind          : Local
    Mount Point   : /Volumes/T7 Backup
    ID            : 12345678-ABCD-1234-ABCD-1234567890AB
    """

    static let RESOLVE_CFG = """
    Site.1.FS.1.Root = /Users/you/Movies
    Site.1.FS.2.Root = /Volumes
    RenderCaching.CacheDir = CacheClip
    """

    // real lines captured live from `diskutil activity` on this machine 2026-08-20:
    static let DU_REAL_VM = "***DiskAppeared ('disk3s6', DAVolumePath = 'file:///System/Volumes/VM/', DAVolumeKind = 'apfs', DAVolumeName = 'VM') Time=20260820-18:07:36.1557"
    static let DU_REAL_NULL = "***DiskAppeared ('disk0', DAVolumePath = '<null>', DAVolumeKind = '<null>', DAVolumeName = '<null>') Time=20260820-18:07:36.1554"
    static let DU_APPEAR = "***DiskAppeared ('disk4s2', DAVolumePath = 'file:///Volumes/T7/', DAVolumeKind = 'apfs', DAVolumeName = 'T7') Time=20260820-18:07:36.1551"
    static let DU_GONE = "***DiskDisappeared ('disk4s2', DAVolumePath = 'file:///Volumes/T7/', DAVolumeKind = 'apfs', DAVolumeName = 'T7') Time=20260820-18:07:40.0001"

    static let DU_INFO_INTERNAL = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
    	<key>BusProtocol</key>
    	<string>Apple Fabric</string>
    	<key>Ejectable</key>
    	<false/>
    	<key>Internal</key>
    	<true/>
    	<key>VolumeName</key>
    	<string>Macintosh HD</string>
    </dict>
    </plist>
    """

    static let DU_INFO_EXTERNAL = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
    	<key>BusProtocol</key>
    	<string>Disk Image</string>
    	<key>Ejectable</key>
    	<true/>
    	<key>Internal</key>
    	<false/>
    	<key>VolumeName</key>
    	<string>PerformacTest</string>
    </dict>
    </plist>
    """

    static let POWER_AC = "Now drawing from 'AC Power'"
    static let POWER_BATT = "Now drawing from 'Battery Power'"

    static func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Int64 {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = s
        return Int64(Calendar.current.date(from: comps)!.timeIntervalSince1970 * 1000)
    }

    static func run(_ c: CheckSuite) async {
        // parsePs
        do {
            let rows = parsePs(PS)
            c.check("parsePs: header skipped, 3 rows", rows.count == 3, "got \(rows.count)")
            c.eq("parsePs: row 1", rows[0], PsRow(pid: 693, cpu: 98.2, rssMb: 71, name: "RobloxPlayer"))
            c.eq("parsePs: row 2", rows[1], PsRow(pid: 172, cpu: 47.5, rssMb: 167, name: "WindowServer"))
            c.eq("parsePs: names with spaces/parens", rows[2].name, "Claude Helper (Renderer)")
            c.eq("parsePs: rssMb rounded", rows[2].rssMb, 601)
        }
        // parseDf
        do {
            let rows = parseDf(DF)
            c.check("parseDf: /dev/disk rows only; devfs dropped", rows.count == 1)
            c.eq("parseDf: mount", rows[0].mount, "/")
            c.check("parseDf: freeGb ≈ 61.77", abs(rows[0].freeGb - 61.77) < 0.01, "got \(rows[0].freeGb)")
            c.check("parseDf: totalGb ≈ 926.3", abs(rows[0].totalGb - 926.3) < 0.05, "got \(rows[0].totalGb)")
            let spaces = parseDf("""
            Filesystem     1024-blocks      Used Available Capacity iused     ifree %iused  Mounted on
            /dev/disk9s2     10485760   1048576   2097152    90%   1000    100000    1%   /Volumes/T7 Backup
            """)
            c.eq("parseDf: mount with spaces joined", spaces[0].mount, "/Volumes/T7 Backup")
        }
        // front app
        c.eq("parseFrontAppName", parseFrontAppName(FRONT), "Zen")
        c.check("parseFrontAppName: garbage → nil", parseFrontAppName("not lsappinfo") == nil)
        // therm
        c.eq("parseTherm: empty", parseTherm(THERM_EMPTY), ThermState(available: false, cpuSpeedLimit: nil))
        c.eq("parseTherm: limit", parseTherm(THERM_LIMIT), ThermState(available: true, cpuSpeedLimit: 70))
        // thermlog
        c.eq("parseThermlogLine: level 1", parseThermlogLine(THERMLOG), 1)
        c.eq("parseThermlogLine: level 0 counts", parseThermlogLine("2026-08-20 13:11:08 +0700 Thermal Warning Level = 0"), 0)
        c.check("parseThermlogLine: unrelated → nil", parseThermlogLine("some unrelated line") == nil)
        // battery
        c.eq("parseBattery: real ioreg fixture", parseBattery(BATT),
             BatteryState(cycleCount: 78, designCap: 6249, nominalCap: 6024, healthPct: 96.4))
        c.check("parseBattery: garbage → nil", parseBattery("garbage") == nil)
        // tm
        c.eq("parseTmDestinations: none", parseTmDestinations(TM_NONE), TmDestinations(configured: false, names: []))
        c.eq("parseTmDestinations: one", parseTmDestinations(TM_ONE), TmDestinations(configured: true, names: ["T7 Backup"]))
        c.eq("parseTmLatest: backup path", parseTmLatest("/Volumes/T7 Backup/2026-08-19-221408.backup"),
             TmLatest(backupISO: "2026-08-19T22:14:08"))
        c.check("parseTmLatest: error text → nil", parseTmLatest("Failed to mount backup destination: No such file or directory") == nil)
        // resolve config
        c.eq("parseResolveConfig", parseResolveConfig(RESOLVE_CFG),
             ResolveConfig(fsRoot: "/Users/you/Movies", cacheDir: "CacheClip"))
        // diskutil activity — real lines
        c.eq("parseDiskutilActivity: appeared with ts", parseDiskutilActivity(DU_APPEAR),
             DiskActivity(kind: "appeared", volume: "T7", ts: local(2026, 8, 20, 18, 7, 36)))
        c.eq("parseDiskutilActivity: disappeared with ts", parseDiskutilActivity(DU_GONE),
             DiskActivity(kind: "disappeared", volume: "T7", ts: local(2026, 8, 20, 18, 7, 40)))
        c.eq("parseDiskutilActivity: real VM line", parseDiskutilActivity(DU_REAL_VM),
             DiskActivity(kind: "appeared", volume: "VM", ts: local(2026, 8, 20, 18, 7, 36)))
        c.check("parseDiskutilActivity: literal '<null>' → nil", parseDiskutilActivity(DU_REAL_NULL) == nil)
        c.check("parseDiskutilActivity: empty name → nil",
                parseDiskutilActivity("***DiskAppeared ('disk4s2', DAVolumeKind = 'apfs', DAVolumeName = '')") == nil)
        c.check("parseDiskutilActivity: other lines → nil", parseDiskutilActivity("***StorageAttached (...)") == nil)
        // diskutil info
        c.eq("parseDiskutilInfo: internal", parseDiskutilInfo(DU_INFO_INTERNAL), DiskInfo(internal: true, ejectable: false))
        c.eq("parseDiskutilInfo: external", parseDiskutilInfo(DU_INFO_EXTERNAL), DiskInfo(internal: false, ejectable: true))
        c.check("parseDiskutilInfo: garbage → nil", parseDiskutilInfo("garbage") == nil)
        // power
        c.eq("parsePower: AC", parsePower(POWER_AC), "AC Power")
        c.eq("parsePower: battery", parsePower(POWER_BATT), "Battery Power")
        c.check("parsePower: nonsense → nil", parsePower("nonsense") == nil)
        // login items
        c.eq("parseLoginItems", parseLoginItems("Ice, AltTab, OneDrive"), ["Ice", "AltTab", "OneDrive"])
        c.eq("parseLoginItems: empty", parseLoginItems(""), [])
        // never throw on garbage
        c.eq("parsers never throw: parsePs(undefined)", parsePs(nil), [])
        c.eq("parsers never throw: parseDf(null)", parseDf(nil), [])
        c.check("parsers never throw: parseFrontAppName", parseFrontAppName(nil) == nil)
        c.eq("parsers never throw: parseTherm", parseTherm(nil), ThermState(available: false, cpuSpeedLimit: nil))
        c.check("parsers never throw: parseThermlogLine", parseThermlogLine(nil) == nil)
        c.check("parsers never throw: parseBattery", parseBattery(nil) == nil)
        c.eq("parsers never throw: parseTmDestinations", parseTmDestinations(nil), TmDestinations(configured: false, names: []))
        c.check("parsers never throw: parseTmLatest", parseTmLatest(nil) == nil)
        c.eq("parsers never throw: parseResolveConfig", parseResolveConfig(nil), ResolveConfig(fsRoot: nil, cacheDir: nil))
        c.check("parsers never throw: parseDiskutilActivity", parseDiskutilActivity(nil) == nil)
        c.eq("parsers never throw: parseLoginItems", parseLoginItems(nil), [])
    }
}
