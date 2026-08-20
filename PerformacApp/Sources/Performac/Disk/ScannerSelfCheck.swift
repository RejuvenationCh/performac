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
        // trashItem even for our own temp tree — the only deletion path allowed in this codebase
        defer { try? fm.trashItem(at: root, resultingItemURL: nil) }
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
        var sawProgress = false
        var finished = false
        for await event in DiskScanner().scan(root) {
            if case .progress = event, !finished { sawProgress = true }
            if case .finished(let sum) = event {
                finished = true
                files = sum.files
                bytes = sum.bytes
                top = sum.topDirectories
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

        // skip-path pruning
        var scanner = DiskScanner()
        scanner.skipPaths = [root.appendingPathComponent("dirB").path]
        var prunedBytes: Int64 = 0
        for await event in scanner.scan(root) {
            if case .finished(let sum) = event { prunedBytes = sum.bytes }
        }
        check("skipPaths prunes subtree", prunedBytes == expectedBytes - 4096, "got \(prunedBytes)")

        return failures == 0 ? 0 : 1
    }
}
