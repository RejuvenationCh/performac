// main.swift — CLI scan mode (the Phase 2 go/no-go measurement) and the menu bar app.
// No arguments: NSApplication bootstrap — Dock icon plus a menu bar item.
// `Performac scan <path>`: headless scan with timings (Phase 2 prototype measurement).
import AppKit
import Foundation

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "scan" {
    exit(await ScanCLI.run(path: CommandLine.arguments[2]))
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "dbcopy" {
    let dest = copyV1DatabaseIfNeeded(v1Path: CommandLine.arguments[2])
    print(dest)
    exit(0)
}
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "parity" {
    // parity mode: open a db copy, run the ported engine's refreshFindings at a fixed
    // `now`, and dump findings as JSON — the Phase 1 acceptance test compares this
    // against v1's engine run over the same database.
    exit(await ParityCLI.run(dbPath: CommandLine.arguments[2], now: Int64(CommandLine.arguments[3]) ?? 0))
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "metrics" {
    let m = LiveMetrics.shared
    _ = m.cpu()                                  // prime the tick delta
    _ = m.network()                              // rates need a previous reading
    try? await Task.sleep(for: .seconds(1))
    let s = m.sample()
    print(String(format: "cpu %.1f%%  mem %.1f/%.1f GB (%.0f%%)  disk %.0f%% used (%.1f free of %.0f)  net down %.0f KB/s up %.0f KB/s  battery %d%%%@  thermal %@",
                 s.cpuPercent, s.memUsedGb, s.memTotalGb, s.memPercent,
                 s.diskUsedPercent, s.freeGb, s.totalGb,
                 s.netDownBps / 1024, s.netUpBps / 1024,
                 s.batteryPercent, s.batteryCharging ? " (charging)" : "", s.thermal))
    exit(0)
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "check" {
    let scanner = await ScannerSelfCheck.run()
    let engine = await runAllChecks()
    exit(scanner != 0 ? scanner : engine)
}

// Any argument we do not recognise exits with usage. Falling through to the GUI meant a
// mistyped flag started a windowless app and hung the caller until it was killed.
if CommandLine.arguments.count > 1 {
    let known = ["scan", "check", "metrics", "dbcopy", "parity"]
    let arg = CommandLine.arguments[1]
    if !known.contains(arg) {
        let usage = """
        Performac usage:
          Performac                   launch the app
          Performac scan <path>       scan a folder and print totals
          Performac metrics           print live CPU / memory / free space
          Performac check             run the self-checks
          Performac dbcopy <db>       seed the v2 database from v1
          Performac parity <db> <ms>  dump findings at a fixed clock

        unknown argument: \(arg)
        """
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// A regular app, not .accessory: it is pinned to the Dock, so it needs a Dock icon with a
// running indicator and a Cmd-Tab entry. The menu bar item stays — an app can have both.
app.setActivationPolicy(.regular)
app.run()
