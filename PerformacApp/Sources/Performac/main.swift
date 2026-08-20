// main.swift — CLI scan mode (the Phase 2 go/no-go measurement) and the menu bar app.
// No arguments: NSApplication bootstrap, LSUIElement menu bar shell (Phase 0).
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
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "check" {
    let scanner = await ScannerSelfCheck.run()
    let engine = await runAllChecks()
    exit(scanner != 0 ? scanner : engine)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
