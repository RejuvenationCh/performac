// Disk/Scanner.swift — concurrent recursive tree sizing, the go/no-go prototype.
//
// Design goals (plan-v2 §Technical risks #1):
//   - FileManager.enumerator (lazy, streaming) + URLResourceValues
//   - .totalFileAllocatedSizeKey: allocated bytes, so totals match Finder/du
//   - bounded parallelism: each 512-item batch is stat'd in `concurrency` slices via
//     DispatchQueue.concurrentPerform. The plan asked for a TaskGroup; the two-stream
//     Task bridge hung under this toolchain (DirectoryEnumerator's iterator is noasync,
//     so enumeration is sync on a background queue, and a sync producer feeding an async
//     consumer never delivered stream termination). concurrentPerform is the same
//     bounded-parallelism semantics with one thread and one stream — simpler, no Tasks.
//   - never follows symlinks (enumerator doesn't descend; symlink items are not counted)
//   - skips /System and configured skip roots (a "/" scan is normalized to the Data
//     volume to avoid firmlink double-counting — see main.swift)
//   - streams .progress events while running so the UI populates progressively
//
// DELETION RULE: this file never deletes anything. The only permitted deletion path
// in this codebase is FileManager.default.trashItem — and it is not used here at all.
import Foundation
import os

/// Cancellation for the synchronous enumerator: Task.isCancelled has no meaning
/// outside a task, so the producer polls this flag instead.
final class CancelFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var _cancelled = false
    var cancelled: Bool { lock.withLock { _cancelled } }
    func cancel() { lock.withLock { _cancelled = true } }
}

public struct ScanSnapshot: Sendable {
    public let filesScanned: Int
    public let bytes: Int64
    public let currentPath: String
    public init(filesScanned: Int, bytes: Int64, currentPath: String) {
        self.filesScanned = filesScanned
        self.bytes = bytes
        self.currentPath = currentPath
    }
}

public struct DirTotal: Sendable {
    public let path: String
    public let files: Int
    public let bytes: Int64
    public init(path: String, files: Int, bytes: Int64) {
        self.path = path
        self.files = files
        self.bytes = bytes
    }
}

public struct ScanSummary: Sendable {
    public let root: String
    public let files: Int
    public let bytes: Int64
    public let elapsed: TimeInterval
    public let topDirectories: [DirTotal]   // immediate children of root, biggest first
    public init(root: String, files: Int, bytes: Int64, elapsed: TimeInterval, topDirectories: [DirTotal]) {
        self.root = root
        self.files = files
        self.bytes = bytes
        self.elapsed = elapsed
        self.topDirectories = topDirectories
    }
}

public enum ScanEvent: Sendable {
    case progress(ScanSnapshot)
    case finished(ScanSummary)
}

public struct DiskScanner: Sendable {
    public var concurrency: Int = 8
    /// Path prefixes to prune entirely (skipDescendants when the enumerator reaches them).
    public var skipPaths: [String] = ["/System", "/Volumes"]
    public var progressInterval: TimeInterval = 0.2

    public init() {}

    public func scan(_ root: URL) -> AsyncStream<ScanEvent> {
        let cancelFlag = CancelFlag()
        return AsyncStream { continuation in
            // DirectoryEnumerator.makeIterator is noasync: enumerate synchronously off-main.
            DispatchQueue.global(qos: .userInitiated).async {
                runSync(root: root, continuation: continuation, cancelFlag: cancelFlag)
            }
            continuation.onTermination = { _ in cancelFlag.cancel() }
        }
    }

    // MARK: — the whole scan runs synchronously on one background queue —

    private func runSync(root: URL, continuation: AsyncStream<ScanEvent>.Continuation, cancelFlag: CancelFlag) {
        // canonicalize with realpath(3): URL.resolvingSymlinksInPath does not resolve
        // firmlinks (/var → /private/var), but the enumerator returns resolved paths —
        // comparisons against the unresolved root/skip paths miss.
        func canon(_ p: String) -> String {
            guard let c = realpath(p, nil) else { return p }
            defer { free(c) }
            return String(cString: c)
        }
        let root = URL(fileURLWithPath: canon(root.path))
        let skip = skipPaths.map(canon)
        func isSkipped(_ url: URL) -> Bool {
            let p = url.path
            return skip.contains { p == $0 || p.hasPrefix($0 + "/") }
        }
        let start = Date()
        var totals: [String: (files: Int, bytes: Int64)] = [:]   // per-directory, by full path
        var filesScanned = 0
        var bytes: Int64 = 0
        var lastPath = root.path
        var lastEmit = Date()

        func emitProgress(force: Bool) {
            let now = Date()
            if force || now.timeIntervalSince(lastEmit) >= progressInterval {
                continuation.yield(.progress(ScanSnapshot(
                    filesScanned: filesScanned, bytes: bytes, currentPath: lastPath)))
                lastEmit = now
            }
        }

        func process(_ batch: [URL]) {
            let sliceLen = max(1, batch.count / concurrency + 1)
            var slices: [[URL]] = []
            var i = 0
            while i < batch.count {
                slices.append(Array(batch[i ..< min(i + sliceLen, batch.count)]))
                i += sliceLen
            }
            var increments: [(String, Int, Int64)] = []
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: slices.count) { idx in
                let r = statSlice(slices[idx])
                lock.lock()
                increments.append(contentsOf: r)
                lock.unlock()
            }
            for (dir, f, b) in increments {
                let cur = totals[dir] ?? (0, 0)
                totals[dir] = (cur.files + f, cur.bytes + b)
                filesScanned += f
                bytes += b
            }
            emitProgress(force: false)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey],
            options: [],
            errorHandler: { _, _ in true }     // EPERM subtrees: degrade, keep going
        ) else {
            continuation.yield(.finished(ScanSummary(
                root: root.path, files: 0, bytes: 0, elapsed: 0, topDirectories: [])))
            continuation.finish()
            return
        }

        var batch: [URL] = []
        batch.reserveCapacity(512)
        for case let url as URL in enumerator {
            if cancelFlag.cancelled { continuation.finish(); return }
            lastPath = url.path
            if isSkipped(url) {
                enumerator.skipDescendants()
                continue
            }
            batch.append(url)
            if batch.count >= 512 {
                process(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { process(batch) }
        emitProgress(force: true)

        // roll up deepest-first: every directory's total includes everything beneath it
        var rolled = totals
        let paths = totals.keys.sorted {
            $0.filter { $0 == "/" }.count > $1.filter { $0 == "/" }.count
        }
        for p in paths {
            let parent = URL(fileURLWithPath: p).deletingLastPathComponent().path
            guard parent != p, let t = rolled[p], var pt = rolled[parent] else { continue }
            pt = (pt.files + t.files, pt.bytes + t.bytes)
            rolled[parent] = pt
        }

        let top: [DirTotal] = rolled
            .filter { $0.key != root.path && URL(fileURLWithPath: $0.key).deletingLastPathComponent().path == root.path }
            .map { DirTotal(path: $0.key, files: $0.value.files, bytes: $0.value.bytes) }
            .sorted { $0.bytes > $1.bytes }

        continuation.yield(.finished(ScanSummary(
            root: root.path,
            files: filesScanned,
            bytes: bytes,
            elapsed: Date().timeIntervalSince(start),
            topDirectories: top)))
        continuation.finish()
    }

    /// Stat one slice of a batch; returns per-parent-dir increments.
    private func statSlice(_ slice: [URL]) -> [(String, Int, Int64)] {
        var out: [(String, Int, Int64)] = []
        out.reserveCapacity(slice.count)
        for url in slice {
            guard let vals = try? url.resourceValues(forKeys: [
                .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
            ]) else { continue }
            if vals.isSymbolicLink == true { continue }   // never count or follow links
            let size = Int64(vals.totalFileAllocatedSize ?? 0)
            out.append((url.deletingLastPathComponent().path, 1, size))
        }
        return out
    }
}
