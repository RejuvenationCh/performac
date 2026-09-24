// Core/FileKind.swift — file-type taxonomy, classified by measurement (extension and
// cache-path membership), not by folder name. The old heuristic guessed from folder-name
// keywords ("movie", "photo", "cache") and matched none of this user's project-shorthand
// folder names (UC, Render, ALP Juna, GMS...), so everything fell to .other. This type is
// engine-layer (used by the scanner while it walks the tree) and carries no SwiftUI
// dependency — its `color` lives in Design/Tokens.swift instead.
import Foundation

public enum FileKind: String, CaseIterable, Sendable {
    case video = "Video", image = "Image", audio = "Audio", cache = "Cache/App Data",
         document = "Document", other = "Other / System"

    private static let videoExts: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mxf", "braw", "r3d", "ari", "dv",
        "mts", "m2ts", "mpg", "mpeg", "webm", "wmv",
    ]
    private static let imageExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp",
        "svg", "psd", "ai", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf",
    ]
    private static let audioExts: Set<String> = [
        "mp3", "wav", "aiff", "aif", "m4a", "flac", "aac", "ogg", "caf",
    ]
    private static let documentExts: Set<String> = [
        "pdf", "doc", "docx", "txt", "md", "rtf", "pages", "key", "numbers",
        "xls", "xlsx", "ppt", "pptx", "csv", "epub",
    ]

    /// Classify one file: cache membership first (a cache hit is disposable regardless of
    /// what it contains), then extension. Cheap string checks only — this runs once per item
    /// in the scanner's hot loop, ~936k times a scan, and must add no stat calls.
    public static func forFile(path: String) -> FileKind {
        if isCachePath(path) { return .cache }
        return forExtension((path as NSString).pathExtension)
    }

    public static func forExtension(_ ext: String) -> FileKind {
        let e = ext.lowercased()
        if videoExts.contains(e) { return .video }
        if imageExts.contains(e) { return .image }
        if audioExts.contains(e) { return .audio }
        if documentExts.contains(e) { return .document }
        return .other
    }

    /// Substring checks rather than splitting into path components — no array allocation
    /// in the per-file hot loop. Every scanned path is absolute, so "/Cache/" or "/Caches/"
    /// as a substring is exactly "a Cache/Caches directory component" the spec asks for.
    static func isCachePath(_ path: String) -> Bool {
        path.contains("/Library/Caches/") || path.contains("/Cache/") || path.contains("/Caches/")
    }
}

/// One Int64 per kind. Rides the scanner's existing per-directory (files, bytes) aggregation:
/// `add` is called once per item alongside the existing byte increment, so classifying costs
/// no second pass and no extra stat call.
public struct KindTally: Sendable {
    public var video: Int64 = 0
    public var image: Int64 = 0
    public var audio: Int64 = 0
    public var cache: Int64 = 0
    public var document: Int64 = 0
    public var other: Int64 = 0
    public init() {}

    public mutating func add(_ kind: FileKind, _ bytes: Int64) {
        switch kind {
        case .video: video += bytes
        case .image: image += bytes
        case .audio: audio += bytes
        case .cache: cache += bytes
        case .document: document += bytes
        case .other: other += bytes
        }
    }

    public mutating func merge(_ other: KindTally) {
        video += other.video; image += other.image; audio += other.audio
        cache += other.cache; document += other.document; self.other += other.other
    }

    /// A directory's colour: whichever kind holds the most bytes beneath it. A tie — including
    /// the all-zero tie of an empty or entirely unclassifiable directory — is not a confident
    /// answer, so it falls to `.other` rather than picking a winner arbitrarily.
    public var dominant: FileKind {
        let pairs: [(FileKind, Int64)] = [
            (.video, video), (.image, image), (.audio, audio),
            (.cache, cache), (.document, document), (.other, other),
        ]
        let maxBytes = pairs.map(\.1).max() ?? 0
        let winners = pairs.filter { $0.1 == maxBytes }
        return winners.count == 1 ? winners[0].0 : .other
    }
}
