// Check/FileKindCheck.swift — the file-type taxonomy that replaced the folder-name guess.
// Written to falsify: an extension misclassified, a cache path let through by extension,
// or a directory rollup picking a kind that isn't actually dominant by bytes.
import Foundation

@MainActor
enum FileKindCheck {
    static func run(_ c: CheckSuite) async {
        // extension classification
        c.eq("kind: .mov is video", FileKind.forFile(path: "/x/clip.mov"), .video)
        c.eq("kind: .psd is image", FileKind.forFile(path: "/x/art.psd"), .image)
        c.eq("kind: .mp3 is audio", FileKind.forFile(path: "/x/track.mp3"), .audio)
        c.eq("kind: .pdf is document", FileKind.forFile(path: "/x/invoice.pdf"), .document)
        c.eq("kind: unknown extension is other", FileKind.forFile(path: "/x/thing.xyz123"), .other)

        // cache path wins over extension, regardless of where the "Cache(s)" component sits
        c.eq("kind: under Library/Caches is cache despite a video extension",
             FileKind.forFile(path: "/Users/me/Library/Caches/App/preview.mov"), .cache)
        c.eq("kind: a bare Caches directory component is cache",
             FileKind.forFile(path: "/Users/me/Projects/Caches/render.mp4"), .cache)

        // directory rollup: dominant kind by bytes
        var mixed = KindTally()
        mixed.add(.video, 10 * 1_000_000_000)
        mixed.add(.image, 1 * 1_000_000_000)
        c.eq("kind: directory of 10 GB video + 1 GB image rolls up to video", mixed.dominant, .video)

        // tie and empty cases both fall to .other, never an arbitrary pick
        var tied = KindTally()
        tied.add(.video, 5_000_000)
        tied.add(.image, 5_000_000)
        c.eq("kind: a byte tie between two kinds resolves to other", tied.dominant, .other)
        c.eq("kind: an empty tally resolves to other", KindTally().dominant, .other)
    }
}
