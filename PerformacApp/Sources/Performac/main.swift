// main.swift — CLI scan mode (the Phase 2 go/no-go measurement) and the menu bar app.
// No arguments: NSApplication bootstrap, LSUIElement menu bar shell (Phase 0).
// `Performac scan <path>`: headless scan with timings (Phase 2 prototype measurement).
import AppKit
import Foundation

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "scan" {
    exit(await ScanCLI.run(path: CommandLine.arguments[2]))
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "check" {
    exit(await ScannerSelfCheck.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
