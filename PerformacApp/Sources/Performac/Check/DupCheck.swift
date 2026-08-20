// DupCheck.swift — the duplicate pipeline, on a real temp tree. Written to falsify:
// the same-size decoy must be eliminated, and a unique-size file must never be a candidate.
import Foundation

enum DupCheck {
    @MainActor static func run(_ c: CheckSuite) async {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "performac-dup-\(UUID().uuidString)"
        let a = root + "/a", b = root + "/b"
        for d in [a, b] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        defer { try? fm.trashItem(at: URL(fileURLWithPath: root), resultingItemURL: nil) }

        // three identical 1 MiB files in different directories
        let payload = Data(repeating: 0x41, count: 1_048_576)
        for p in ["\(a)/one.bin", "\(b)/two.bin", "\(root)/three.bin"] { fm.createFile(atPath: p, contents: payload) }
        // same SIZE, different content — must survive bucketing but die at hashing
        var decoy = Data(repeating: 0x41, count: 1_048_576); decoy[1_048_575] = 0x42
        fm.createFile(atPath: "\(a)/decoy.bin", contents: decoy)
        // unique size — must never even be a candidate
        fm.createFile(atPath: "\(b)/lonely.bin", contents: Data(repeating: 0x43, count: 2_097_152))

        let s = DupScanner()
        var groups: [DupGroupResult] = []
        for await ev in s.scan(roots: [root], minMb: 1) {
            if case .finished(let g) = ev { groups = g }
        }

        c.check("dup: exactly one group found", groups.count == 1)
        c.check("dup: the group holds all three true copies", groups.first?.paths.count == 3)
        c.check("dup: same-size decoy eliminated",
                groups.first?.paths.contains { $0.hasSuffix("decoy.bin") } == false)
        c.check("dup: unique-size file never grouped",
                groups.allSatisfy { !$0.paths.contains { $0.hasSuffix("lonely.bin") } })
        c.check("dup: wasted counts copies beyond the first", groups.first?.wastedMb == 2)

        // partial hashing must actually differ for same-size different-content files
        let h1 = s.partialHash("\(a)/one.bin", size: 1_048_576)
        let h2 = s.partialHash("\(a)/decoy.bin", size: 1_048_576)
        c.check("dup: partial hash reads the tail (decoy differs)", h1 != nil && h1 != h2)
        c.check("dup: full hash matches for identical files",
                s.fullHash("\(a)/one.bin") == s.fullHash("\(b)/two.bin"))

        // skip rules
        c.check("dup: ~/Library is skipped",
                s.skipDir(NSHomeDirectory() + "/Library", home: NSHomeDirectory(), username: "me"))
        c.check("dup: another user's home is skipped",
                s.skipDir("/Users/someoneelse", home: "/Users/me", username: "me"))
        c.check("dup: /System is skipped", s.skipDir("/System", home: "/Users/me", username: "me"))
        c.check("dup: a normal project dir is not skipped",
                !s.skipDir("/Users/me/Movies", home: "/Users/me", username: "me"))
    }
}
