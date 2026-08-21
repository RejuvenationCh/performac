// CleanView.swift — replaces Purge. Allowlisted caches only, Trash-only, every row explains why.
import SwiftUI
import AppKit

struct CleanView: View {
    @State private var caches: [CacheEntry]
    @State private var confirming = false
    /// Anchor for shift-click range selection.
    @State private var lastToggled: Int? = nil
    @State private var sort = SortState()

    private let onTrash: ([CacheEntry]) -> Void
    var busy: Bool = false
    var progress: String = ""
    var summary: String? = nil

    init(caches: [CacheEntry] = Sample.caches, busy: Bool = false, progress: String = "",
         summary: String? = nil, onTrash: @escaping ([CacheEntry]) -> Void = { _ in }) {
        self.busy = busy; self.progress = progress; self.summary = summary
        _caches = State(initialValue: caches)
        self.onTrash = onTrash
    }
    /// Indices into `caches`, in the order the sort asks for.
    private var displayOrder: [Int] {
        let wanted = caches.sorted(by: sort).map(\.id)
        var index: [UUID: Int] = [:]
        for (i, c) in caches.enumerated() { index[c.id] = i }
        return wanted.compactMap { index[$0] }
    }

    private var selected: [CacheEntry] { caches.filter { $0.selected && $0.cleanable } }

    /// Click anywhere on a row to toggle it. Shift-click selects the whole run from the last
    /// row you touched, the way a file list does — clicking twelve checkboxes to clear a
    /// cache list is busywork.
    private func toggle(_ i: Int, shift: Bool) {
        guard caches.indices.contains(i), caches[i].cleanable else { return }
        if shift, let anchor = lastToggled, anchor != i {
            // walk the DISPLAYED order: a range should be what the user sees between two
            // rows, not whatever happens to sit between them in the unsorted array.
            let order = displayOrder
            guard let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: i) else { return }
            let target = caches[anchor].selected
            for k in min(a, b)...max(a, b) where caches[order[k]].cleanable {
                caches[order[k]].selected = target
            }
        } else {
            caches[i].selected.toggle()
            lastToggled = i
        }
    }
    private var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        Page(title: "Clean",
             subtitle: "Caches apps rebuild on their own. Nothing here is deleted — it goes to the Trash.") {
            VStack(spacing: 0) {
                HStack(spacing: PC.gutter) {
                    Toggle("", isOn: Binding(
                        get: { let c = caches.filter(\.cleanable); return !c.isEmpty && c.allSatisfy(\.selected) },
                        set: { v in for i in caches.indices where caches[i].cleanable { caches[i].selected = v } }))
                        .labelsHidden().toggleStyle(.checkbox)
                    SortHeader(title: "NAME", key: .name, state: $sort)
                    SortHeader(title: "SIZE", key: .size, state: $sort, width: 70, alignment: .trailing)
                    SortHeader(title: "LAST WRITTEN", key: .date, state: $sort, width: 100, alignment: .trailing)
                    SortHeader(title: "STATUS", key: .status, state: $sort, width: 96, alignment: .leading)
                }
                .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2)
                .background(PC.canvas).pcHairline(.bottom)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Sorted for display, but each row keeps a binding into the real
                        // array — sorting a list must never scramble which row a click hits.
                        ForEach(displayOrder, id: \.self) { i in
                            CacheRow(entry: $caches[i], onRowTap: { shift in toggle(i, shift: shift) })
                            Divider().overlay(PC.hairline)
                        }
                    }
                }
                .background(PC.surface)

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        if busy {
                            HStack(spacing: PC.s2) {
                                ProgressView().controlSize(.small).scaleEffect(0.7)
                                Text(progress).font(.pcTitle).foregroundStyle(PC.ink)
                            }
                            Text("Large caches hold hundreds of thousands of files, so this takes a moment.")
                                .font(.pcSmall).foregroundStyle(PC.meta)
                        } else {
                            Text("\(selected.count) selected — \(Fmt.bytes(selectedBytes))")
                                .font(.pcTitle).foregroundStyle(PC.ink)
                            Text(summary ?? "Everything goes to the Trash and stays recoverable.")
                                .font(.pcSmall).foregroundStyle(PC.meta)
                        }
                    }
                    Spacer()
                    // DESIGN.md: this label is fixed. Never "Clean", "Optimize", or "Free up".
                    Button("Move to Trash") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty || busy)
                }
                .padding(.horizontal, PC.stack).padding(.vertical, PC.gutter)
                .background(PC.surface).pcHairline(.top)
            }
            .sheet(isPresented: $confirming) {
                TrashSheet(items: selected,
                           onCancel: { confirming = false },
                           onConfirm: {
                               confirming = false
                               onTrash(selected)
                           })
            }
        }
    }
}

struct CacheRow: View {
    @Binding var entry: CacheEntry
    var onRowTap: (Bool) -> Void = { _ in }
    @State private var hover = false
    var body: some View {
        HStack(alignment: .top, spacing: PC.gutter) {
            if entry.cleanable {
                // the checkbox reflects state; the row is the hit target
                Toggle("", isOn: $entry.selected).labelsHidden().toggleStyle(.checkbox)
                    .padding(.top, 1).allowsHitTesting(false)
            } else {
                // Protected: measured and shown, but the app will not trash it.
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(PC.meta)
                    .frame(width: 14).padding(.top, 3)
                    .help("Not on the cleaner's allowlist — Performac will not trash this.")
            }
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
        .background(entry.selected ? PC.fill2 : (hover ? PC.fill1.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            guard entry.cleanable else { return }
            onRowTap(NSEvent.modifierFlags.contains(.shift))
        }
        .onHover { hover = $0 }
        .help(entry.cleanable ? "Click to select. Shift-click to select a range."
                              : "Not on the cleaner's allowlist — Performac will not trash this.")
    }
}

/// The one irreversible-feeling moment. DESIGN.md: blue button (recoverable, not dangerous),
/// Cancel focused, full paths and sizes, recoverability stated.
struct TrashSheet: View {
    let items: [CacheEntry]
    var onCancel: () -> Void
    var onConfirm: () -> Void
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
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Move to Trash", action: onConfirm).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(width: 520)
        .pcGlassPanel(PC.rXl)
    }
}
