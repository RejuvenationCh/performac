// CleanView.swift — replaces Purge. Allowlisted caches only, Trash-only, every row explains why.
import SwiftUI

struct CleanView: View {
    @State private var caches: [CacheEntry] = Sample.caches
    @State private var confirming = false
    private var selected: [CacheEntry] { caches.filter(\.selected) }
    private var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        Page(title: "Clean",
             subtitle: "Caches apps rebuild on their own. Nothing here is deleted — it goes to the Trash.") {
            VStack(spacing: 0) {
                HStack(spacing: PC.gutter) {
                    Toggle("", isOn: Binding(
                        get: { !caches.isEmpty && caches.allSatisfy(\.selected) },
                        set: { v in for i in caches.indices { caches[i].selected = v } }))
                        .labelsHidden().toggleStyle(.checkbox)
                    Text("NAME").font(.pcLabel).foregroundStyle(PC.meta)
                    Spacer()
                    Text("SIZE").font(.pcLabel).foregroundStyle(PC.meta).frame(width: 70, alignment: .trailing)
                    Text("LAST WRITTEN").font(.pcLabel).foregroundStyle(PC.meta).frame(width: 100, alignment: .trailing)
                    Text("STATUS").font(.pcLabel).foregroundStyle(PC.meta).frame(width: 96, alignment: .leading)
                }
                .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2)
                .background(PC.canvas).pcHairline(.bottom)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($caches) { $c in
                            CacheRow(entry: $c)
                            Divider().overlay(PC.hairline)
                        }
                    }
                }
                .background(PC.surface)

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(selected.count) selected — \(Fmt.bytes(selectedBytes))")
                            .font(.pcTitle).foregroundStyle(PC.ink)
                        Text("Everything goes to the Trash and stays recoverable.")
                            .font(.pcSmall).foregroundStyle(PC.meta)
                    }
                    Spacer()
                    // DESIGN.md: this label is fixed. Never "Clean", "Optimize", or "Free up".
                    Button("Move to Trash") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty)
                }
                .padding(.horizontal, PC.stack).padding(.vertical, PC.gutter)
                .background(PC.surface).pcHairline(.top)
            }
            .sheet(isPresented: $confirming) {
                TrashSheet(items: selected) { confirming = false }
            }
        }
    }
}

struct CacheRow: View {
    @Binding var entry: CacheEntry
    @State private var hover = false
    var body: some View {
        HStack(alignment: .top, spacing: PC.gutter) {
            Toggle("", isOn: $entry.selected).labelsHidden().toggleStyle(.checkbox).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.pcBody).foregroundStyle(PC.ink)
                Text(entry.why).font(.pcSmall).foregroundStyle(PC.ink2)   // mandatory why-line
            }
            Spacer(minLength: PC.s2)
            Text(Fmt.bytes(entry.bytes)).font(.pcNum).foregroundStyle(PC.ink)
                .frame(width: 70, alignment: .trailing)
            Text(entry.age).font(.pcNum).foregroundStyle(PC.meta)
                .frame(width: 100, alignment: .trailing)
            Pill(text: entry.safe ? "Safe to clean" : "Check first",
                 tint: entry.safe ? PC.green : PC.amber,
                 soft: entry.safe ? PC.greenSoft : PC.amberSoft)
                .frame(width: 96, alignment: .leading)
        }
        .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2 + 1)
        .background(hover ? PC.fill1.opacity(0.6) : .clear)
        .onHover { hover = $0 }
    }
}

/// The one irreversible-feeling moment. DESIGN.md: blue button (recoverable, not dangerous),
/// Cancel focused, full paths and sizes, recoverability stated.
struct TrashSheet: View {
    let items: [CacheEntry]
    var onClose: () -> Void
    private var total: Int64 { items.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Move \(items.count) item\(items.count == 1 ? "" : "s") to the Trash?")
                .font(.pcHeadline).foregroundStyle(PC.ink)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, PC.gutter)

            VStack(spacing: 0) {
                ForEach(items) { i in
                    HStack(alignment: .top, spacing: PC.gutter) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.name).font(.pcBody).foregroundStyle(PC.ink)
                            Text(i.path).font(.pcSmall).foregroundStyle(PC.meta).lineLimit(1)
                        }
                        Spacer()
                        Text(Fmt.bytes(i.bytes)).font(.pcNum).foregroundStyle(PC.ink)
                    }
                    .padding(.horizontal, 24).padding(.vertical, PC.s2)
                }
            }
            HStack {
                Spacer()
                Text("\(Fmt.bytes(total)) total").font(.pcTitle).foregroundStyle(PC.ink)
            }
            .padding(.horizontal, 24).padding(.vertical, PC.s2 + 2)
            .pcHairline(.top).pcHairline(.bottom)

            HStack(alignment: .top, spacing: PC.gutter) {
                Image(systemName: "trash.fill").font(.system(size: 14)).foregroundStyle(PC.meta)
                Text("These go to the Trash, not deleted. You can put them back from Finder until you empty it.")
                    .font(.pcSmall).foregroundStyle(PC.ink2).lineSpacing(2)
            }
            .padding(.horizontal, 24).padding(.vertical, PC.stack)

            HStack(spacing: PC.s2 + 2) {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Move to Trash", action: onClose).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(width: 520)
        .background(PC.surface)
    }
}
