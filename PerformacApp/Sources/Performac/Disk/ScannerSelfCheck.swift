// Disk/ScannerSelfCheck.swift — `Performac check`: synthetic-tree correctness checks
// for DiskScanner (sizing must match du). CommandLineTools ships neither swift-testing
// nor XCTest, so the checks are assert-based and runnable, not a test framework.
import Foundation

enum ScannerSelfCheck {
    static func run() async -> Int32 {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print("\(cond ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !cond { failures += 1 }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("performac-check-\(UUID().uuidString)")
        // fixtures are left in NSTemporaryDirectory for the system to purge
        // fixtures live in NSTemporaryDirectory and are left for the system to purge
        try? fm.createDirectory(at: root.appendingPathComponent("dirA"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("dirB/sub"), withIntermediateDirectories: true)
        var payload = Data(count: 100 * 1024)
        for i in payload.indices { payload[i] = UInt8(i % 251) }
        try? payload.write(to: root.appendingPathComponent("dirA/f1"))
        try? Data(count: 4096).write(to: root.appendingPathComponent("dirA/f2"))
        try? Data(count: 4096).write(to: root.appendingPathComponent("dirB/sub/f3"))
        try? fm.createSymbolicLink(
            at: root.appendingPathComponent("linkToA"),
            withDestinationURL: root.appendingPathComponent("dirA"))
        let expectedBytes = Int64(payload.count) + 2 * 4096

        var files = 0
        var bytes: Int64 = 0
        var top: [DirTotal] = []
        var allEntries: [ScanEntry] = []
        var sawProgress = false
        var finished = false
        for await event in DiskScanner().scan(root) {
            if case .progress = event, !finished { sawProgress = true }
            if case .finished(let sum) = event {
                finished = true
                files = sum.files
                bytes = sum.bytes
                top = sum.topDirectories
                allEntries = sum.entries
            }
        }
        // dirs count as items too (du counts them); the symlink must not
        check("items counted (6: 3 files + 3 dirs, symlink excluded)", files == 6, "got \(files)")
        check("bytes == written payload (du parity)", bytes == expectedBytes, "got \(bytes), want \(expectedBytes)")
        let byName = Dictionary(uniqueKeysWithValues: top.map {
            (URL(fileURLWithPath: $0.path).lastPathComponent, $0.bytes)
        })
        check("per-dir dirA total (recursive)", byName["dirA"] == Int64(payload.count) + 4096, "got \(byName["dirA"] ?? -1)")
        check("per-dir dirB total (recursive, includes sub/f3)", byName["dirB"] == 4096, "got \(byName["dirB"] ?? -1)")
        check("progress streams before finish", sawProgress)

        // The browser descends without rescanning, so the summary must carry the WHOLE tree,
        // not just the top level. A nested directory that only appears at depth 2 proves it.
        let entries = allEntries
        let dirs = entries.filter { $0.isDirectory }.map { $0.path }
        check("tree: nested dir present at depth 2",
              dirs.contains { $0.hasSuffix("/dirB/sub") }, "dirs=\(dirs.count)")
        check("tree: every top-level dir is in entries",
              dirs.contains { $0.hasSuffix("/dirA") } && dirs.contains { $0.hasSuffix("/dirB") })
        check("tree: entries carry rolled-up totals",
              entries.first { $0.path.hasSuffix("/dirB") }?.bytes == 4096)
        // children lookup by parent is what the view uses to descend
        let kids = entries.filter { ($0.path as NSString).deletingLastPathComponent.hasSuffix("/dirB") }
        check("tree: dirB has a navigable child", kids.contains { $0.path.hasSuffix("/sub") })

        // skip-path pruning
        var scanner = DiskScanner()
        scanner.skipPaths = [root.appendingPathComponent("dirB").path]
        var prunedBytes: Int64 = 0
        for await event in scanner.scan(root) {
            if case .finished(let sum) = event { prunedBytes = sum.bytes }
        }
        check("skipPaths prunes subtree", prunedBytes == expectedBytes - 4096, "got \(prunedBytes)")

        // The case that shipped broken: /Volumes is skipped so a scan of Home does not wander
        // onto an external drive — but choosing that drive made the root its own skip path, so
        // every child was pruned and the scan finished with 0 files in 0.0 s. A skip path that
        // contains the chosen root must be ignored, or the drive looks unscannable.
        var rootSkipped = DiskScanner()
        rootSkipped.skipPaths = [root.path]
        var rootSkippedBytes: Int64 = -1
        for await event in rootSkipped.scan(root) {
            if case .finished(let sum) = event { rootSkippedBytes = sum.bytes }
        }
        check("skipPaths equal to the root does not prune the whole scan",
              rootSkippedBytes == expectedBytes, "got \(rootSkippedBytes)")

        // an ancestor of the root is the same mistake one level up (/System vs
        // /System/Volumes/Data, which is where a scan of "/" is redirected)
        var ancestorSkipped = DiskScanner()
        ancestorSkipped.skipPaths = [root.deletingLastPathComponent().path]
        var ancestorBytes: Int64 = -1
        for await event in ancestorSkipped.scan(root) {
            if case .finished(let sum) = event { ancestorBytes = sum.bytes }
        }
        check("skipPaths above the root does not prune the whole scan",
              ancestorBytes == expectedBytes, "got \(ancestorBytes)")

        // and the pruning that IS wanted still works when the root sits under nothing skipped
        var siblingSkipped = DiskScanner()
        siblingSkipped.skipPaths = ["/System", "/Volumes"]
        var siblingBytes: Int64 = -1
        for await event in siblingSkipped.scan(root) {
            if case .finished(let sum) = event { siblingBytes = sum.bytes }
        }
        check("unrelated skipPaths leave a scan alone",
              siblingBytes == expectedBytes, "got \(siblingBytes)")

        return failures == 0 ? 0 : 1
    }
}
