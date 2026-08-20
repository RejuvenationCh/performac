// DiskView.swift — replaces OmniDiskSweeper (drill-down list) and GrandPerspective (treemap).
// Layout follows the Stitch artifact: breadcrumb + storage bar above a 60/40 split.
import SwiftUI

struct DiskView: View {
    var entries: [SizeEntry] = Sample.disk
    var scanning: Bool = false
    var scanFiles: Int = 0
    var scanBytes: Int64 = 0
    var scanElapsed: TimeInterval = 0
    var scanPath: String = ""
    var onScan: () -> Void = {}
    var onCancel: () -> Void = {}
    private var maxBytes: Int64 { entries.map(\.bytes).max() ?? 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Breadcrumb(parts: ["Macintosh HD", "Users", "rejuvenation"])
                Spacer()
                StorageBar(freeBytes: 70_866_000_000, totalBytes: 1_068_000_000_000)
            }
            .padding(.horizontal, PC.stack).padding(.vertical, PC.gutter)
            .background(PC.surface).pcHairline(.bottom)

            if scanning {
                ScanProgress(files: scanFiles, bytes: scanBytes, elapsed: scanElapsed,
                             currentPath: scanPath, onCancel: onCancel)
            }

            HSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: PC.gutter) {
                        Text("NAME").font(.pcLabel).foregroundStyle(PC.meta)
                        Spacer()
                        Text("ITEMS").font(.pcLabel).foregroundStyle(PC.meta).frame(width: 64, alignment: .trailing)
                        Text("SIZE").font(.pcLabel).foregroundStyle(PC.meta).frame(width: 72, alignment: .trailing)
                        Text("PROPORTION").font(.pcLabel).foregroundStyle(PC.meta).frame(width: 90, alignment: .leading)
                    }
                    .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2)
                    .background(PC.canvas).pcHairline(.bottom)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { e in
                                SizeRow(entry: e, maxBytes: maxBytes)
                                Divider().overlay(PC.hairline)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Text("\(entries.count) items").font(.pcSmall).foregroundStyle(PC.meta)
                        Spacer()
                        Button("Scan Again", action: onScan)
                            .buttonStyle(.link).font(.pcLabel)
                    }
                    .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2)
                    .pcHairline(.top)
                }
                .frame(minWidth: 380, idealWidth: 560)
                .background(PC.surface)

                VStack(spacing: 0) {
                    TreeMap(entries: entries).padding(PC.s2)
                    TreeMapLegend().padding(.horizontal, PC.gutter).padding(.bottom, PC.gutter)
                }
                .frame(minWidth: 260)
                .background(PC.canvas)
            }
        }
    }
}

struct Breadcrumb: View {
    let parts: [String]
    var body: some View {
        HStack(spacing: PC.s1) {
            Image(systemName: "internaldrive").font(.system(size: 12)).foregroundStyle(PC.meta)
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(PC.meta) }
                Text(p).font(.pcBody)
                    .foregroundStyle(i == parts.count - 1 ? PC.ink : PC.ink2)
                    .fontWeight(i == parts.count - 1 ? .semibold : .regular)
            }
        }
    }
}

/// Streaming scan state — this is what you look at most while using Disk.
struct ScanProgress: View {
    var files: Int = 0
    var bytes: Int64 = 0
    var elapsed: TimeInterval = 0
    var currentPath: String = ""
    var onCancel: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: PC.s1) {
            HStack {
                Text("Scanning… \(Fmt.count(files)) items · \(Fmt.bytes(bytes)) so far")
                    .font(.pcBody).foregroundStyle(PC.ink)
                Spacer()
                Text("\(Int(elapsed) / 60):\(String(format: "%02d", Int(elapsed) % 60))")
                    .font(.pcNum).foregroundStyle(PC.meta)
                Button("Cancel", action: onCancel).buttonStyle(.link).font(.pcLabel)
            }
            ProgressView().progressViewStyle(.linear).tint(PC.accentFill)
            Text(currentPath)
                .font(.pcSmall).foregroundStyle(PC.meta).lineLimit(1).truncationMode(.head)
        }
        .padding(.horizontal, PC.stack).padding(.vertical, PC.s2 + 2)
        .background(PC.surface).pcHairline(.bottom)
    }
}

// MARK: squarified treemap — DESIGN.md rules out the strip layout the artifact drew
struct TreeMap: View {
    let entries: [SizeEntry]
    var body: some View {
        GeometryReader { g in
            let rects = squarify(entries.map { Double($0.bytes) },
                                 CGRect(origin: .zero, size: g.size))
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                if i < rects.count {
                    let r = rects[i]
                    RoundedRectangle(cornerRadius: PC.r)
                        .fill(e.kind.color)
                        .overlay(RoundedRectangle(cornerRadius: PC.r).stroke(.white.opacity(0.7), lineWidth: 1))
                        .overlay(alignment: .topLeading) {
                            if r.width > 54 && r.height > 22 {
                                Text(e.name).font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.black.opacity(0.65))
                                    .padding(4).lineLimit(1)
                            }
                        }
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .help("\(e.name) — \(Fmt.bytes(e.bytes))")
                }
            }
        }
    }
}

/// Squarified treemap: pack rows toward square aspect ratios so small items stay clickable.
func squarify(_ values: [Double], _ bounds: CGRect) -> [CGRect] {
    guard !values.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
    let total = values.reduce(0, +)
    guard total > 0 else { return [] }
    var areas = values.map { $0 / total * Double(bounds.width * bounds.height) }
    var out: [CGRect] = []
    var rect = bounds
    var row: [Double] = []
    var idx = 0

    func worst(_ row: [Double], _ side: Double) -> Double {
        guard let mn = row.min(), let mx = row.max(), !row.isEmpty else { return .infinity }
        let s = row.reduce(0, +), s2 = s * s, w2 = side * side
        return max(w2 * mx / s2, s2 / (w2 * mn))
    }
    func layout(_ row: [Double], _ horizontal: Bool) {
        let s = row.reduce(0, +)
        let thick = horizontal ? s / Double(rect.width) : s / Double(rect.height)
        var off: Double = 0
        for a in row {
            let len = a / thick
            out.append(horizontal
                ? CGRect(x: rect.minX + off, y: rect.minY, width: len, height: thick)
                : CGRect(x: rect.minX, y: rect.minY + off, width: thick, height: len))
            off += len
        }
        rect = horizontal
            ? CGRect(x: rect.minX, y: rect.minY + thick, width: rect.width, height: rect.height - thick)
            : CGRect(x: rect.minX + thick, y: rect.minY, width: rect.width - thick, height: rect.height)
    }

    while idx < areas.count {
        let horizontal = rect.width >= rect.height
        let side = Double(horizontal ? rect.width : rect.height)
        let next = areas[idx]
        if row.isEmpty || worst(row + [next], side) <= worst(row, side) {
            row.append(next); idx += 1
        } else {
            layout(row, horizontal); row = []
        }
        if rect.width <= 0 || rect.height <= 0 { break }
    }
    if !row.isEmpty { layout(row, rect.width >= rect.height) }
    return out
}

struct TreeMapLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PC.s1) {
            SectionHeader(text: "File types")
            ForEach(FileKind.allCases, id: \.self) { k in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(k.color).frame(width: 9, height: 9)
                    Text(k.rawValue).font(.pcSmall).foregroundStyle(PC.ink2)
                }
            }
        }
        .padding(PC.s2 + 2).frame(maxWidth: .infinity, alignment: .leading).pcCard()
    }
}
