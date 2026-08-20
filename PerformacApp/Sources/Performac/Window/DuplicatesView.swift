// DuplicatesView.swift — exact matches only. No bulk action: with duplicates one copy must
// survive, so trashing every copy can never be a single misclick (DESIGN.md §Do not carry over).
import SwiftUI

struct DuplicatesView: View {
    var groups: [DupGroup] = Sample.dups
    private var recoverable: Int64 {
        groups.reduce(0) { $0 + $1.bytes * Int64(max($1.paths.count - 1, 0)) }
    }
    var body: some View {
        Page(title: "Duplicates",
             subtitle: "Exact matches only — same file, byte for byte. \(groups.count) groups, \(Fmt.bytes(recoverable)) recoverable.",
             trailing: AnyView(
                HStack(spacing: PC.gutter) {
                    Text("Last scan: 3 hours ago").font(.pcSmall).foregroundStyle(PC.meta)
                    Button("Scan Again") {}.controlSize(.small)
                })) {
            ScrollView {
                VStack(spacing: PC.gutter) {
                    ForEach(groups) { g in DupGroupCard(group: g) }
                }
                .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
            }
        }
    }
}

private struct DupGroupCard: View {
    let group: DupGroup
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
                DupPathRow(path: p)
            }
        }
        .pcCard()
    }
}

private struct DupPathRow: View {
    let path: String
    @State private var hover = false
    var body: some View {
        HStack(spacing: PC.s2) {
            Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(PC.meta)
            Text(path).font(.pcSmall).foregroundStyle(PC.ink2).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: PC.s2)
            if hover {
                IconButton("magnifyingglass", help: "Reveal in Finder")
                IconButton("trash", help: "Move this copy to the Trash")
            }
        }
        .padding(.horizontal, PC.gutter).padding(.vertical, 6)
        .background(hover ? PC.fill1.opacity(0.6) : .clear)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}
