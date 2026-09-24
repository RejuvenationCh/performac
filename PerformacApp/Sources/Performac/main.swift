// main.swift — CLI scan mode (the Phase 2 go/no-go measurement) and the menu bar app.
// No arguments: NSApplication bootstrap — Dock icon plus a menu bar item.
// `Performac scan <path>`: headless scan with timings (Phase 2 prototype measurement).
import AppKit
import Foundation

/// tiny flag for the contention bench
final class ManagedAtomicFlag: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    var value: Bool { get { l.lock(); defer { l.unlock() }; return v }
                      set { l.lock(); v = newValue; l.unlock() } }
}

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
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "rowsbench" {
    let db = DB(path: NSHomeDirectory() + "/Library/Application Support/com.chris.performac.v2/performac.db")
    func children(_ path: String) -> Int {
        db.prepare("SELECT name, items, bytes, is_dir FROM scan_entries WHERE parent = ? ORDER BY bytes DESC")
            .all([.text(path)]).count
    }
    let home = NSHomeDirectory()
    var t = Date()
    let top = children(home)
    print(String(format: "  one childrenOf(home): %.1f ms (%d rows)", Date().timeIntervalSince(t) * 1000, top))
    t = Date()
    for _ in 0..<50 { _ = children(home) }
    print(String(format: "  50x childrenOf(home): %.1f ms", Date().timeIntervalSince(t) * 1000))
    t = Date()
    for _ in 0..<50 { _ = children(home + "/Library") }
    print(String(format: "  50x childrenOf(~/Library): %.1f ms", Date().timeIntervalSince(t) * 1000))
    exit(0)
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "contend" {
    let path = NSHomeDirectory() + "/Library/Application Support/com.chris.performac.v2/performac.db"
    let writer = DB(path: path)
    let home = NSHomeDirectory()
    // a background writer doing what a tick does
    let stop = ManagedAtomicFlag()
    Thread.detachNewThread {
        while !stop.value {
            writer.prepare("INSERT INTO proc_samples(ts,pid,name,cpu,rss_mb) VALUES(?,?,?,?,?)")
                .run([.int(1), .int(1), .text("bench"), .int(0), .int(0)])
        }
    }
    func timeReads(_ label: String, _ db: DB) {
        let t = Date()
        for _ in 0..<20 {
            _ = db.prepare("SELECT name FROM scan_entries WHERE parent = ? ORDER BY bytes DESC").all([.text(home)])
        }
        print(String(format: "  %-34s %7.1f ms for 20 reads", (label as NSString).utf8String!, Date().timeIntervalSince(t) * 1000))
    }
    timeReads("same connection as the writer", writer)
    timeReads("separate read-only connection", DB(path: path, readOnly: true))
    stop.value = true
    try? await Task.sleep(for: .milliseconds(200))
    writer.prepare("DELETE FROM proc_samples WHERE name = ?").run([.text("bench")])
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
    let known = ["scan", "check", "metrics", "dbcopy", "parity", "rowsbench", "contend"]
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
