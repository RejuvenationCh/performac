// DupScanner.swift — on-demand exact-duplicate scan, ported from v1's dedupe.js.
//
// Pipeline, unchanged from v1: walk (files >= minMb) -> size buckets -> 128 KB head+tail
// partial SHA-256 -> full-stream SHA-256 for survivors. Exact matches only: no fuzzy or
// near-duplicate matching, so there is never a judgement call to get wrong.
//
// Streamed hashing throughout. Candidates are media files measured in gigabytes; reading
// one into memory would be a multi-GB allocation per file.
import CryptoKit
import Foundation

struct DupGroupResult: Sendable {
    var hash: String
    var sizeMb: Int64
    var paths: [String]
    /// Bytes recoverable if every copy but one were removed.
    var wastedMb: Int64 { sizeMb * Int64(max(paths.count - 1, 0)) }
}

enum DupScanEvent: Sendable {
    case progress(hashed: Int, candidates: Int, currentPath: String)
    case finished([DupGroupResult])
}

final class DupScanner: @unchecked Sendable {
    private let chunk = 4 * 1024 * 1024
    private let partialLen = 128 * 1024

    func scan(roots: [String], minMb: Int64) -> AsyncStream<DupScanEvent> {
        AsyncStream { continuation in
            let work = Task.detached(priority: .utility) { [self] in
                let minBytes = minMb * 1_048_576
                // ---- 1. walk, bucketed by exact byte size ----
                var bySize: [Int64: [String]] = [:]
                for root in roots {
                    walk(root, minBytes: minBytes) { path, size in
                        bySize[size, default: []].append(path)
                    }
                    if Task.isCancelled { return }
                }
                let candidates = bySize.values.filter { $0.count > 1 }.reduce(0) { $0 + $1.count }

                // ---- 2. partial hash (head + tail) — cheap elimination ----
                var byPartial: [String: (size: Int64, files: [String])] = [:]
                var hashed = 0
                for (size, files) in bySize where files.count > 1 {
                    for file in files {
                        if Task.isCancelled { return }
                        hashed += 1
                        if hashed % 8 == 0 {
                            continuation.yield(.progress(hashed: hashed, candidates: candidates, currentPath: file))
                        }
                        guard let h = partialHash(file, size: size) else { continue }
                        byPartial[h, default: (size, [])].files.append(file)
                    }
                }

                // ---- 3. full hash only for partial survivors ----
                var groups: [DupGroupResult] = []
                for (_, bucket) in byPartial where bucket.files.count > 1 {
                    var byFull: [String: [String]] = [:]
                    for file in bucket.files {
                        if Task.isCancelled { return }
                        continuation.yield(.progress(hashed: hashed, candidates: candidates, currentPath: file))
                        guard let h = fullHash(file) else { continue }
                        byFull[h, default: []].append(file)
                    }
                    for (hash, paths) in byFull where paths.count > 1 {
                        groups.append(DupGroupResult(hash: hash,
                                                     sizeMb: bucket.size / 1_048_576,
                                                     paths: paths.sorted()))
                    }
                }
                groups.sort { $0.wastedMb > $1.wastedMb }
                continuation.yield(.finished(groups))
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: hashing

    func partialHash(_ path: String, size: Int64) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        let headLen = min(Int64(partialLen), size)
        guard let head = try? fh.read(upToCount: Int(headLen)) else { return nil }
        h.update(data: head)
        if size > headLen {
            let tailLen = min(Int64(partialLen), size - headLen)
            try? fh.seek(toOffset: UInt64(size - tailLen))
            if let tail = try? fh.read(upToCount: Int(tailLen)) { h.update(data: tail) }
        }
        return hex(h.finalize())
    }

    func fullHash(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        while let part = try? fh.read(upToCount: chunk), !part.isEmpty {
            h.update(data: part)
        }
        return hex(h.finalize())
    }

    private func hex(_ d: SHA256Digest) -> String {
        d.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: walk — v1's skip rules exactly

    func walk(_ root: String, minBytes: Int64, _ onFile: (String, Int64) -> Void) {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let username = (home as NSString).lastPathComponent
        var stack = [(root as NSString).expandingTildeInPath]
        while let dir = stack.popLast() {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names {
                if name.hasPrefix(".") { continue }            // dotfiles and dot-dirs
                let p = (dir as NSString).appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: p) else { continue }
                let type = attrs[.type] as? FileAttributeType
                if type == .typeSymbolicLink { continue }       // never followed, never counted
                if type == .typeDirectory {
                    if !skipDir(p, home: home, username: username) { stack.append(p) }
                } else if type == .typeRegular {
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    if size >= minBytes { onFile(p, size) }
                }
            }
        }
    }

    func skipDir(_ p: String, home: String, username: String) -> Bool {
        if p == (home as NSString).appendingPathComponent("Library") { return true }
        let parts = p.split(separator: "/").map(String.init)
        if parts.first == "Users", parts.count > 1, parts[1] != username { return true }
        if parts.count == 1, parts[0] == "System" || parts[0] == "private" { return true }
        return false
    }
}
