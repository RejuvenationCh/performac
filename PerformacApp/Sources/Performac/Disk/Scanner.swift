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
public final class CancelFlag: @unchecked Sendable {
    public init() {}
    private let lock = OSAllocatedUnfairLock()
    private var _cancelled = false
    public var cancelled: Bool { lock.withLock { _cancelled } }
    public func cancel() { lock.withLock { _cancelled = true } }
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

/// One row a browser can show: a directory (with its rolled-up total) or a large file.
/// Files below this never appear as their own row — they are counted in their folder's
/// total. Without a floor a home directory would produce ~900k rows.
let largeFileMin: Int64 = 10 * 1_048_576

public struct ScanEntry: Sendable {
    public let path: String
    public let files: Int
    public let bytes: Int64
    public let isDirectory: Bool
    /// Newest modification time beneath this entry (or its own, for a file). Epoch ms,
    /// 0 when unknown — the column sorts unknowns last rather than pretending they are 1970.
    public let mtime: Int64
    public init(path: String, files: Int, bytes: Int64, isDirectory: Bool, mtime: Int64 = 0) {
        self.path = path; self.files = files; self.bytes = bytes
        self.isDirectory = isDirectory; self.mtime = mtime
    }
    public var parent: String { (path as NSString).deletingLastPathComponent }
    public var name: String { (path as NSString).lastPathComponent }
}

public struct ScanSummary: Sendable {
    public let root: String
    public let files: Int
    public let bytes: Int64
    public let elapsed: TimeInterval
    public let topDirectories: [DirTotal]   // immediate children of root, biggest first
    /// Every directory in the tree plus every file over `largeFileMin`, so the browser can
    /// descend without rescanning. The roll-up is already computed; keeping it costs nothing.
    public let entries: [ScanEntry]
    /// True when the walk was stopped early. What is here is real, it is just not all of it.
    public let partial: Bool
    public init(root: String, files: Int, bytes: Int64, elapsed: TimeInterval,
                topDirectories: [DirTotal], entries: [ScanEntry] = [], partial: Bool = false) {
        self.entries = entries
        self.partial = partial
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
    /// Eight workers is right for flash and wrong for rust. On a spinning disk they make the
    /// head seek between eight regions instead of reading in something like order, so the
    /// scan gets slower the more of them there are. See `DiskScanner.concurrency(forVolume:)`.
    public var concurrency: Int = 8

    /// `diskutil info -plist` reports SolidState for flash and omits it for a spinning disk.
    /// Metadata only — this reads no files and does not touch the volume's contents.
    public static func concurrency(forVolume path: String) -> Int {
        guard path.hasPrefix("/Volumes/") else { return 8 }   // the boot disk is flash
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 8 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        // absent means "not reported as solid state", which for a USB disk means rust
        let solid = text.contains("<key>SolidState</key>")
            && text.range(of: "<key>SolidState</key>\\s*<true/>", options: .regularExpression) != nil
        return solid ? 8 : 2
    }
    /// Path prefixes to prune entirely (skipDescendants when the enumerator reaches them).
    public var skipPaths: [String] = ["/System", "/Volumes"]
    public var progressInterval: TimeInterval = 0.2

    public init() {}

    /// `cancel` is the caller's, so stopping a scan lets the walk unwind and hand back what
    /// it already measured. Tearing the stream down instead throws that away, which on a
    /// spinning 2 TB drive means throwing away half an hour.
    public func scan(_ root: URL, cancel: CancelFlag = CancelFlag()) -> AsyncStream<ScanEvent> {
        let cancelFlag = cancel
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
        // A skip path that contains the chosen root would prune the entire scan on its first
        // entry. /Volumes is on the list so a scan of Home does not wander onto an external
        // drive — but picking that drive skipped every one of its children and finished with
        // 0 files in 0.0 s, which read as "the drive cannot be scanned". Same for /System when
        // the root is /System/Volumes/Data, which is where a scan of "/" is redirected.
        let skip = skipPaths.map(canon).filter { root.path != $0 && !root.path.hasPrefix($0 + "/") }
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
            var increments: [(String, String, Int64, Int64)] = []
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: slices.count) { idx in
                let r = statSlice(slices[idx])
                lock.lock()
                increments.append(contentsOf: r)
                lock.unlock()
            }
            for (dir, filePath, b, mt) in increments {
                let cur = totals[dir] ?? (0, 0)
                totals[dir] = (cur.files + 1, cur.bytes + b)
                filesScanned += 1
                bytes += b
                newest[dir] = max(newest[dir] ?? 0, mt)      // folder date = newest thing in it
                if b >= largeFileMin {
                    largeFiles.append(ScanEntry(path: filePath, files: 0, bytes: b,
                                                isDirectory: false, mtime: mt))
                }
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
                root: root.path, files: 0, bytes: 0, elapsed: 0, topDirectories: [],
                partial: true)))
            continuation.finish()
            return
        }

        var largeFiles: [ScanEntry] = []
        var newest: [String: Int64] = [:]
        var batch: [URL] = []
        batch.reserveCapacity(512)
        var stopped = false
        for case let url as URL in enumerator {
            if cancelFlag.cancelled { stopped = true; break }
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

        // roll the newest date upward the same way sizes were rolled
        var rolledMtime = newest
        for p in paths {
            let parent = URL(fileURLWithPath: p).deletingLastPathComponent().path
            guard parent != p, let t = rolledMtime[p] else { continue }
            rolledMtime[parent] = max(rolledMtime[parent] ?? 0, t)
        }
        var entries: [ScanEntry] = rolled.map {
            ScanEntry(path: $0.key, files: $0.value.files, bytes: $0.value.bytes,
                      isDirectory: true, mtime: rolledMtime[$0.key] ?? 0)
        }
        entries.append(contentsOf: largeFiles)

        continuation.yield(.finished(ScanSummary(
            root: root.path,
            files: filesScanned,
            bytes: bytes,
            elapsed: Date().timeIntervalSince(start),
            topDirectories: top,
            entries: entries,
            partial: stopped)))
        continuation.finish()
    }

    /// Stat one slice of a batch; returns per-parent-dir increments.
    /// (parent directory, file path, allocated size)
    private func statSlice(_ slice: [URL]) -> [(String, String, Int64, Int64)] {
        var out: [(String, String, Int64, Int64)] = []
        out.reserveCapacity(slice.count)
        for url in slice {
            guard let vals = try? url.resourceValues(forKeys: [
                .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
            ]) else { continue }
            if vals.isSymbolicLink == true { continue }   // never count or follow links
            let size = Int64(vals.totalFileAllocatedSize ?? 0)
            let mt = Int64((vals.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            out.append((url.deletingLastPathComponent().path, url.path, size, mt))
        }
        return out
    }
}
