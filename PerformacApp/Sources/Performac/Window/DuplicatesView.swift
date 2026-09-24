// DuplicatesView.swift — exact matches only. No bulk action: with duplicates one copy must
// survive, so trashing every copy can never be a single misclick (DESIGN.md §Do not carry over).
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
    private var recoverable: Int64 {
        groups.reduce(0) { $0 + $1.bytes * Int64(max($1.paths.count - 1, 0)) }
    }
    var body: some View {
        Page(title: "Duplicates",
             subtitle: "Exact matches only — same file, byte for byte. \(groups.count) groups, \(Fmt.bytes(recoverable)) recoverable.",
             trailing: AnyView(
                HStack(spacing: PC.gutter) {
                    TickingAgo(date: lastScanAt, prefix: "Last scan: ").font(.pcSmall).foregroundStyle(PC.meta).monospacedDigit()
                    if scanning {
                        Button("Cancel", action: onCancel).controlSize(.small)
                    } else {
                        Button(groups.isEmpty ? "Scan" : "Scan Again", action: onScan)
                            .controlSize(.small)
                            .help("Hashes files over the size threshold. Exact matches only.")
                    }
                })) {
            if scanning {
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
            ScrollView {
                VStack(spacing: PC.gutter) {
                    ForEach(groups) { g in
                        DupGroupCard(group: g, onReveal: onReveal,
                                     infoTarget: $infoTarget, trashTarget: $trashTarget)
                    }
                }
                .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
            }
        }
        .onDisappear(perform: onDisappear)
        .sheet(item: $infoTarget) { RowInfoSheet(info: $0) { infoTarget = nil } }
        .sheet(item: $trashTarget) { t in
            RowTrashSheet(info: t, onCancel: { trashTarget = nil },
                          onConfirm: { trashTarget = nil; onTrashPath(t.path) })
        }
    }
}

private struct DupGroupCard: View {
    let group: DupGroup
    let onReveal: (String) -> Void
    @Binding var infoTarget: RowInfo?
    @Binding var trashTarget: RowInfo?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PC.s2) {
                Text(Fmt.bytes(group.bytes)).font(.pcNumLg).foregroundStyle(PC.ink)
                Pill(text: "\(group.paths.count) copies", tint: PC.accent, soft: PC.fill1)
                Text(group.name).font(.pcTitle).foregroundStyle(PC.ink).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2 + 2)
            .pcHairline(.bottom)

            ForEach(Array(group.paths.enumerated()), id: \.offset) { _, p in
                DupPathRow(path: p, bytes: group.bytes, onReveal: onReveal,
                           infoTarget: $infoTarget, trashTarget: $trashTarget)
            }
        }
        .pcCard()
    }
}

/// One copy. Per-copy actions only — never a bulk one, because with exact duplicates at least
/// one copy has to survive (DESIGN.md §Do not carry over #5). That rule was already written
/// down; these two buttons are what it asked for, and they were empty closures.
private struct DupPathRow: View {
    let path: String
    let bytes: Int64
    let onReveal: (String) -> Void
    @Binding var infoTarget: RowInfo?
    @Binding var trashTarget: RowInfo?
    @State private var hover = false

    private var info: RowInfo {
        RowInfo(path: (path as NSString).expandingTildeInPath,
                name: (path as NSString).lastPathComponent,
                bytes: bytes, items: 0, isFolder: false)
    }

    var body: some View {
        HStack(spacing: PC.s2) {
            Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(PC.meta)
            Text(path).font(.pcSmall).foregroundStyle(PC.ink2).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: PC.s2)
            if hover {
                IconButtonAction("magnifyingglass", help: "Reveal in Finder") { onReveal(info.path) }
                IconButtonAction("trash", help: "Move this copy to the Trash…") { trashTarget = info }
            }
        }
        .padding(.horizontal, PC.gutter).padding(.vertical, 6)
        .background(hover ? PC.fill1.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .rowActions(info, infoTarget: $infoTarget, trashTarget: $trashTarget)
        .help(path)
    }
}
