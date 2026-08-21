// DiskModes.swift — the four ways the Disk view can draw the current folder.
// Outline is the default: the only one that shows depth without losing your place.
import SwiftUI
import AppKit

// MARK: - Outline (default): expandable tree, children loaded on demand

struct OutlineList: View {
    let entries: [SizeEntry]
    let basePath: String
    let loadChildren: (String) -> [SizeEntry]
    let onReveal: (String) -> Void
    @Binding var infoTarget: RowInfo?
    @Binding var trashTarget: RowInfo?

    /// Which paths are open, and the children fetched for them. Held here rather than in
    /// per-row @State so collapsing actually frees the rows.
    @State private var expanded: Set<String> = []
    @State private var kids: [String: [SizeEntry]] = [:]

    /// The visible tree, flattened to one array.
    ///
    /// This used to be a recursive View struct: an OutlineRow whose body contained more
    /// OutlineRows. SwiftUI has to materialise that nested generic type for every row even
    /// when collapsed, which is why the outline lagged noticeably where the flat list did
    /// not. One LazyVStack over a flat array only builds what is on screen.
    private struct Flat: Identifiable {
        let id: String          // full path: stable across expand and collapse
        let entry: SizeEntry
        let depth: Int
        let maxBytes: Int64
    }

    private var rows: [Flat] {
        var out: [Flat] = []
        func walk(_ items: [SizeEntry], _ parent: String, _ depth: Int) {
            let localMax = items.map(\.bytes).max() ?? 1
            for e in items {
                let path = (parent as NSString).appendingPathComponent(e.name)
                out.append(Flat(id: path, entry: e, depth: depth, maxBytes: localMax))
                if expanded.contains(path), let children = kids[path] {
                    walk(children, path, depth + 1)
                }
            }
        }
        walk(entries, basePath, 0)
        return out
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { r in
                    OutlineRow(entry: r.entry, path: r.id, depth: r.depth,
                               maxBytes: r.maxBytes,
                               isExpanded: expanded.contains(r.id),
                               onToggle: { toggle(r.id) },
                               onReveal: onReveal,
                               infoTarget: $infoTarget, trashTarget: $trashTarget)
                }
            }
        }
    }

    private func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
            kids[path] = nil                       // collapsing frees the rows
        } else {
            if kids[path] == nil { kids[path] = loadChildren(path) }
            expanded.insert(path)
        }
    }
}

/// A plain row. No recursion, no per-row state, no child loading — the list above owns all
/// three, so this only draws.
private struct OutlineRow: View {
    let entry: SizeEntry
    let path: String
    let depth: Int
    let maxBytes: Int64
    let isExpanded: Bool
    let onToggle: () -> Void
    let onReveal: (String) -> Void
    @Binding var infoTarget: RowInfo?
    @Binding var trashTarget: RowInfo?

    @State private var hover = false
    private var isFolder: Bool { entry.symbol == "folder.fill" }

    var body: some View {
        HStack(spacing: PC.s2) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isFolder ? PC.ink2 : .clear)
                    .frame(width: 12)
            }
            .buttonStyle(.plain).disabled(!isFolder)

            Image(systemName: entry.symbol).font(.system(size: 12))
                .foregroundStyle(entry.kind.color).frame(width: 15)
            Text(entry.name).font(.pcBody).foregroundStyle(PC.ink).lineLimit(1)
            Spacer(minLength: PC.s2)
            if hover { IconButtonAction("magnifyingglass", help: "Reveal in Finder") { onReveal(path) } }
            if entry.items > 0 {
                Text(Fmt.count(entry.items)).font(.pcNum).foregroundStyle(PC.meta)
                    .frame(width: 58, alignment: .trailing)
            }
            Text(Fmt.bytes(entry.bytes)).font(.pcNum).foregroundStyle(PC.ink)
                .frame(width: 70, alignment: .trailing)
            ProportionBar(fraction: Double(entry.bytes) / Double(max(maxBytes, 1)))
                .frame(width: 70, height: 4)
        }
        .padding(.horizontal, PC.gutter).padding(.vertical, 5)
        .background(hover ? PC.fill1 : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if isFolder { onToggle() } }
        .onHover { hover = $0 }
        .rowActions(RowInfo(path: path, name: entry.name, bytes: entry.bytes,
                            items: entry.items, isFolder: isFolder),
                    onOpen: isFolder ? onToggle : nil,
                    infoTarget: $infoTarget, trashTarget: $trashTarget)
    }
}

// MARK: - Compact: one dense line per item, no bars, maximum rows on screen

struct CompactList: View {
    let entries: [SizeEntry]
    let onOpen: (String) -> Void
    let basePath: String
    @Binding var infoTarget: RowInfo?
    @Binding var trashTarget: RowInfo?
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { e in
                    CompactRow(entry: e, onOpen: onOpen)
                        .rowActions(RowInfo(path: (basePath as NSString).appendingPathComponent(e.name),
                                            name: e.name, bytes: e.bytes, items: e.items,
                                            isFolder: e.symbol == "folder.fill"),
                                    onOpen: { onOpen(e.name) },
                                    infoTarget: $infoTarget, trashTarget: $trashTarget)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct CompactRow: View {
    let entry: SizeEntry
    let onOpen: (String) -> Void
    @State private var hover = false
    private var isFolder: Bool { entry.symbol == "folder.fill" }
    var body: some View {
        HStack(spacing: PC.s2) {
            Image(systemName: entry.symbol).font(.system(size: 10))
                .foregroundStyle(entry.kind.color).frame(width: 12)
            Text(entry.name).font(.pcSmall).foregroundStyle(PC.ink).lineLimit(1)
            if isFolder {
                Image(systemName: "chevron.right").font(.system(size: 7))
                    .foregroundStyle(hover ? PC.accent : PC.meta.opacity(0.45))
            }
            Spacer(minLength: PC.s1)
            Text(Fmt.bytes(entry.bytes)).font(.system(size: 11).monospacedDigit())
                .foregroundStyle(PC.ink2)
        }
        .padding(.horizontal, PC.gutter).padding(.vertical, 2)
        .background(hover ? PC.fill1 : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if isFolder { onOpen(entry.name) } }
        .onHover { h in withAnimation(.easeOut(duration: 0.10)) { hover = h } }
        .help(isFolder ? "Double-click to open \(entry.name)" : entry.name)
    }
}

// MARK: - Bubbles: proportional circles, the Space Lens shape

struct BubbleView: View {
    let entries: [SizeEntry]
    let onOpen: (String) -> Void
    /// Beyond this the circles are too small to hit; the rest collapse into one "Other".
    private let maxBubbles = 12

    private var shown: [(entry: SizeEntry, isOther: Bool)] {
        let sorted = entries.sorted { $0.bytes > $1.bytes }
        guard sorted.count > maxBubbles else { return sorted.map { ($0, false) } }
        let head = sorted.prefix(maxBubbles - 1).map { ($0, false) }
        let rest = sorted.dropFirst(maxBubbles - 1)
        let other = SizeEntry(name: "Other items", items: rest.count,
                              bytes: rest.reduce(0) { $0 + $1.bytes }, symbol: "ellipsis.circle", kind: .other)
        return head + [(other, true)]
    }

    var body: some View {
        GeometryReader { g in
            let items = shown
            let placed = pack(items.map { Double($0.entry.bytes) }, in: g.size)
            ZStack {
                ForEach(Array(items.enumerated()), id: \.element.entry.id) { i, item in
                    if i < placed.count {
                        let c = placed[i]
                        Bubble(entry: item.entry, radius: c.r, isOther: item.isOther)
                            .position(x: c.x, y: c.y)
                            .onTapGesture(count: 2) { if !item.isOther { onOpen(item.entry.name) } }
                    }
                }
            }
        }
    }

    /// Largest at the centre, the rest spiralled outward and nudged until they do not
    /// overlap. n is capped at 12, so an O(n^2) collision check is free.
    private func pack(_ values: [Double], in size: CGSize) -> [(x: CGFloat, y: CGFloat, r: CGFloat)] {
        guard let maxV = values.max(), maxV > 0 else { return [] }
        let bound = min(size.width, size.height)
        let rMax = bound * 0.24
        let radii = values.map { CGFloat(max(($0 / maxV).squareRoot(), 0.10)) * rMax }
        var out: [(CGFloat, CGFloat, CGFloat)] = []
        let cx = size.width / 2, cy = size.height / 2
        for (i, r) in radii.enumerated() {
            if i == 0 { out.append((cx, cy, r)); continue }
            var angle = Double(i) * 2.39996                 // golden angle: even spread
            var dist = radii[0] + r + 8
            var placedOK = false
            var guardCount = 0
            while !placedOK && guardCount < 400 {
                let x = cx + CGFloat(cos(angle)) * dist
                let y = cy + CGFloat(sin(angle)) * dist
                let clash = out.contains { p in
                    hypot(p.0 - x, p.1 - y) < p.2 + r + 6
                }
                let inside = x - r > 0 && x + r < size.width && y - r > 0 && y + r < size.height
                if !clash && inside { out.append((x, y, r)); placedOK = true }
                else { angle += 0.35; dist += 1.5; guardCount += 1 }
            }
            if !placedOK { out.append((cx, cy, 0)) }         // no room: draw nothing
        }
        return out.map { (x: $0.0, y: $0.1, r: $0.2) }
    }
}

private struct Bubble: View {
    let entry: SizeEntry
    let radius: CGFloat
    let isOther: Bool
    @State private var hover = false
    var body: some View {
        ZStack {
            Circle()
                .fill(entry.kind.color.opacity(hover ? 0.42 : 0.26))
                .overlay(Circle().stroke(entry.kind.color.opacity(0.85), lineWidth: hover ? 2 : 1))
            // Label anything that can hold text. Only genuinely tiny circles stay bare —
            // a clipped half-word is worse than none.
            // Text has to fit the square inscribed in the circle (side = r * √2), not the
            // circle's width. Sizes are proportional with NO floor: a floor is what made
            // small bubbles show oversized, truncated labels like "SquidS… / 7.4 GB".
            if radius > 14 {
                let box = radius * 1.414
                VStack(spacing: 0) {
                    if radius > 34 {
                        Image(systemName: isOther ? "ellipsis" : entry.symbol)
                            .font(.system(size: min(radius * 0.24, 15)))
                            .foregroundStyle(PC.ink2)
                            .padding(.bottom, 1)
                    }
                    Text(entry.name)
                        .font(.system(size: min(radius * 0.21, 12), weight: .medium))
                        .foregroundStyle(PC.ink)
                        .lineLimit(1).minimumScaleFactor(0.5).truncationMode(.middle)
                    Text(Fmt.bytes(entry.bytes))
                        .font(.system(size: min(radius * 0.185, 11)).monospacedDigit())
                        .foregroundStyle(PC.ink2)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                .frame(width: box - 4)
            }
        }
        .frame(width: radius * 2, height: radius * 2)
        .help("\(entry.name) — \(Fmt.bytes(entry.bytes))")
        .onHover { hover = $0 }
    }
}

// MARK: - shared bits

struct ProportionBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(PC.fill3)
                Capsule().fill(PC.accentFill).frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}

struct IconButtonAction: View {
    let name: String, help: String, action: () -> Void
    init(_ name: String, help: String, action: @escaping () -> Void) {
        self.name = name; self.help = help; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11)).foregroundStyle(PC.ink2)
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.plain).help(help)
    }
}
