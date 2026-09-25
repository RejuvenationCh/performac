// DuplicatesView.swift: exact matches only. No bulk action: with duplicates one copy must
// survive, so trashing every copy can never be a single misclick.
//
// A dense table, not a stack of cards. The job on this screen is comparing two *locations* and
// deciding which copy to lose, so the layout is built around that one comparison:
//
//   * the size sits in a fixed right-aligned column, so the whole list shares one left edge.
//     A variable-width size at the head of each card pushed the name to a different x on every
//     row, which is what made the screen look broken before anything else did.
//   * a path row shows its DIRECTORY, never the filename: the filename is the group title and
//     repeating it at the end of both paths is the one part guaranteed to be identical.
//   * the shared leading directories are dimmed and only the part where the copies diverge is
//     printed at full strength. Two of these paths differed at component nine out of twelve;
//     finding that by eye is the work, and the view should do it for you.
//   * actions are always visible. Hover-only icons made a screen with no working actions and a
//     screen with working actions look exactly the same at rest.
import SwiftUI

struct DuplicatesView: View {
    var groups: [DupGroup] = []
    var scanning: Bool = false
    var hashed: Int = 0
    var candidates: Int = 0
    var currentPath: String = ""
    var onScan: () -> Void = {}
    var onCancel: () -> Void = {}
    var onDisappear: () -> Void = {}
    var lastScanAt: Date? = nil
    var onReveal: (String) -> Void = { _ in }
    var onTrashPath: (String) -> Void = { _ in }
    @State private var infoTarget: RowInfo? = nil
    @State private var trashTarget: RowInfo? = nil

    /// Wide enough for a deeply nested path, narrow enough that the row's actions stay near
    /// the path they act on rather than pinned to the far edge of a big display.
    static let contentWidth: CGFloat = 1040

    /// What you get back by keeping one copy of each group.
    private var recoverable: Int64 {
        groups.reduce(0) { $0 + $1.bytes * Int64(max($1.paths.count - 1, 0)) }
    }

    var body: some View {
        Page(title: "Duplicates",
             subtitle: groups.isEmpty
                ? "Exact matches only: same file, byte for byte."
                : "Exact matches only: same file, byte for byte. \(groups.count) groups, \(Fmt.bytes(recoverable)) recoverable.",
             trailing: AnyView(
                HStack(spacing: PC.gutter) {
                    TickingAgo(date: lastScanAt, prefix: "Last scan: ")
                        .font(.pcSmall).foregroundStyle(PC.meta).monospacedDigit()
                    if scanning {
                        Button("Cancel", action: onCancel).controlSize(.small)
                    } else {
                        Button(groups.isEmpty ? "Scan" : "Scan Again", action: onScan)
                            .controlSize(.small)
                            .help("Hashes files over the size threshold. Exact matches only.")
                    }
                })) {
            VStack(spacing: 0) {
                if scanning { progressBar }

                if groups.isEmpty && !scanning {
                    emptyState
                } else {
                    HStack(spacing: PC.gutter) {
                        Text("SIZE").font(.pcLabel).foregroundStyle(PC.meta)
                            .frame(width: 72, alignment: .trailing)
                        Text("FILE").font(.pcLabel).foregroundStyle(PC.meta)
                        Spacer()
                    }
                    .padding(.horizontal, PC.stack).padding(.vertical, PC.s2)
                    .frame(maxWidth: Self.contentWidth, alignment: .leading)
                    .background(PC.canvas).pcHairline(.bottom)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(groups) { g in
                                DupGroup_Rows(group: g, onReveal: onReveal,
                                              infoTarget: $infoTarget, trashTarget: $trashTarget)
                            }
                        }
                        // Capped, like Settings. Trailing-aligned actions on a full-width row
                        // sat ~800pt from the path they act on: a long trip to a destructive
                        // control, and far enough that the eye stopped associating the two.
                        .frame(maxWidth: Self.contentWidth, alignment: .leading)
                    }
                    .background(PC.surface)
                }
            }
        }
        .onDisappear(perform: onDisappear)
        .sheet(item: $infoTarget) { RowInfoSheet(info: $0) { infoTarget = nil } }
        .sheet(item: $trashTarget) { t in
            RowTrashSheet(info: t, onCancel: { trashTarget = nil },
                          onConfirm: { trashTarget = nil; onTrashPath(t.path) })
        }
    }

    private var progressBar: some View {
        HStack(spacing: PC.s2) {
            ProgressView().controlSize(.small)
            Text(candidates > 0
                 ? "Hashing \(Fmt.count(hashed)) of \(Fmt.count(candidates)) candidates…"
                 : "Looking for same-size files…")
                .font(.pcSmall).foregroundStyle(PC.ink2)
            Text(currentPath).font(.pcSmall).foregroundStyle(PC.meta)
                .lineLimit(1).truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, PC.stack).padding(.vertical, PC.s2)
        .background(PC.fill1).pcHairline(.bottom)
    }

    private var emptyState: some View {
        VStack(spacing: PC.s2) {
            Image(systemName: lastScanAt == nil ? "doc.on.doc" : "checkmark.seal.fill")
                .font(.system(size: 26))
                .foregroundStyle(lastScanAt == nil ? PC.meta : PC.green)
            Text(lastScanAt == nil ? "Not scanned yet" : "No duplicates")
                .font(.pcTitle).foregroundStyle(PC.ink)
            Text(lastScanAt == nil
                 ? "Scanning hashes every file over the size threshold in Settings."
                 : "Nothing in the scanned folders matches another file byte for byte.")
                .font(.pcSmall).foregroundStyle(PC.ink2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
    }
}

/// One group: a heading row carrying the size and filename, then one row per copy.
private struct DupGroup_Rows: View {
    let group: DupGroup
    let onReveal: (String) -> Void
    @Binding var infoTarget: RowInfo?
    @Binding var trashTarget: RowInfo?

    /// Directory components shared by every copy. Printed dimmed so the divergence stands out.
    private var sharedPrefix: [String] {
        let parts = group.paths.map { Self.dirComponents($0) }
        guard var common = parts.first else { return [] }
        for p in parts.dropFirst() {
            var i = 0
            while i < common.count, i < p.count, common[i] == p[i] { i += 1 }
            common = Array(common.prefix(i))
        }
        // Never dim the whole thing: if two copies sit in the same directory they differ only
        // by filename, and dimming every component would leave nothing to read.
        return common.count == parts.first?.count ? Array(common.dropLast()) : common
    }

    static func dirComponents(_ path: String) -> [String] {
        let dir = (path as NSString).deletingLastPathComponent
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return dir.split(separator: "/").map(String.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PC.gutter) {
                Text(Fmt.bytes(group.bytes)).font(.pcNum).fontWeight(.semibold)
                    .foregroundStyle(PC.ink)
                    .frame(width: 72, alignment: .trailing)
                Text(group.name).font(.pcBody).foregroundStyle(PC.ink)
                    .lineLimit(1).truncationMode(.middle)
                // Earns its place only when it says something "2 copies" does not: every
                // group has at least two, so the common case is not worth a badge.
                if group.paths.count > 2 {
                    Pill(text: "\(group.paths.count) copies", tint: PC.accent, soft: PC.fill1)
                }
                Spacer(minLength: PC.s2)
            }
            .padding(.horizontal, PC.stack).padding(.top, PC.s2 + 2).padding(.bottom, 2)

            ForEach(Array(group.paths.enumerated()), id: \.offset) { _, p in
                DupPathRow(path: p, bytes: group.bytes, shared: sharedPrefix,
                           onReveal: onReveal,
                           infoTarget: $infoTarget, trashTarget: $trashTarget)
            }
        }
        .padding(.bottom, PC.s2)
        .pcHairline(.bottom)
    }
}

/// One copy. Per-copy actions only: never a bulk one, because with exact duplicates at least
/// one copy has to survive.
private struct DupPathRow: View {
    let path: String
    let bytes: Int64
    let shared: [String]
    let onReveal: (String) -> Void
    @Binding var infoTarget: RowInfo?
    @Binding var trashTarget: RowInfo?
    @State private var hover = false

    private var info: RowInfo {
        RowInfo(path: (path as NSString).expandingTildeInPath,
                name: (path as NSString).lastPathComponent,
                bytes: bytes, items: 0, isFolder: false)
    }

    private var components: [String] { DupGroup_Rows.dirComponents(path) }

    var body: some View {
        HStack(spacing: PC.gutter) {
            Spacer().frame(width: 72)            // aligns under the size column
            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(PC.meta)
            pathText
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: PC.s2)
            IconButtonAction("magnifyingglass", help: "Reveal in Finder") { onReveal(info.path) }
            IconButtonAction("trash", help: "Move this copy to the Trash…") { trashTarget = info }
        }
        .padding(.horizontal, PC.stack).padding(.vertical, 4)
        .background(hover ? PC.fill1 : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .rowActions(info, infoTarget: $infoTarget, trashTarget: $trashTarget)
        .help(path)
    }

    /// Shared leading directories dimmed, the diverging tail at full strength.
    private var pathText: Text {
        var s = AttributedString()
        for (i, c) in components.enumerated() {
            var run = AttributedString(c + (i == components.count - 1 ? "" : "/"))
            run.foregroundColor = (i < shared.count && shared[i] == c) ? PC.meta : PC.ink
            s += run
        }
        return Text(s).font(.pcSmall)
    }
}
