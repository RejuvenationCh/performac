// CleanView.swift — replaces Purge. Allowlisted caches only, Trash-only, every row explains why.
//
// The list is NOT copied into @State. It used to be: `_caches = State(initialValue: caches)`
// seeds once and then ignores the parameter forever, so every later value of
// `store.cacheEntries` was invisible here. That is what made trashing look broken — the store
// dropped the rows immediately (EngineStore.afterTrash) and this view kept rendering its
// original snapshot until you navigated away and back. Only the selection is view-local.
import SwiftUI
import AppKit

struct CleanView: View {
    var caches: [CacheEntry] = Sample.caches
    var busy: Bool = false
    var progress: String = ""
    var summary: String? = nil
    var breakdowns: [String: CacheBreakdown] = [:]
    var inspectingPaths: Set<String> = []
    var onInspect: (CacheEntry) -> Void = { _ in }
    var onTrash: ([CacheEntry]) -> Void = { _ in }

    /// Selected paths. A path survives the list being replaced, which an index would not.
    @State private var selection: Set<String> = []
    /// Anchor for shift-click range selection.
    @State private var lastToggled: String? = nil
    @State private var sort = SortState()
    @State private var confirming = false

    private var displayed: [CacheEntry] { caches.sorted(by: sort) }
    private var cleanable: [CacheEntry] { caches.filter(\.cleanable) }
    private var selected: [CacheEntry] {
        // Derived, so a row the store has removed cannot linger in the total.
        caches.filter { $0.cleanable && selection.contains($0.path) }
    }
    private var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.bytes } }
    private var allSelected: Bool {
        !cleanable.isEmpty && cleanable.allSatisfy { selection.contains($0.path) }
    }

    /// Click anywhere on a row to toggle it. Shift-click selects the whole run from the last
    /// row you touched, the way a file list does — clicking twelve checkboxes to clear a
    /// cache list is busywork.
    private func toggle(_ path: String, shift: Bool) {
        guard let entry = caches.first(where: { $0.path == path }), entry.cleanable else { return }
        // Walk the DISPLAYED order: a range should be what the user sees between two rows.
        let order = displayed.filter(\.cleanable).map(\.path)
        if shift, let anchor = lastToggled, anchor != path,
           let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: path) {
            let turningOn = selection.contains(anchor)
            for p in order[min(a, b)...max(a, b)] {
                if turningOn { selection.insert(p) } else { selection.remove(p) }
            }
        } else {
            if selection.contains(path) { selection.remove(path) } else { selection.insert(path) }
            lastToggled = path
        }
    }

    private func setAll(_ on: Bool) {
        if on { selection.formUnion(cleanable.map(\.path)) }
        else { selection.subtract(cleanable.map(\.path)) }
    }

    var body: some View {
        Page(title: "Clean",
             subtitle: "Caches apps rebuild on their own. Nothing here is deleted — it goes to the Trash.") {
            VStack(spacing: 0) {
                HStack(spacing: PC.gutter) {
                    Toggle("", isOn: Binding(get: { allSelected }, set: setAll))
                        .labelsHidden().toggleStyle(.checkbox)
                        .help(allSelected ? "Deselect all" : "Select every cleanable cache")
                    SortHeader(title: "NAME", key: .name, state: $sort)
                    SortHeader(title: "SIZE", key: .size, state: $sort, width: 70, alignment: .trailing)
                    SortHeader(title: "LAST WRITTEN", key: .date, state: $sort, width: 100, alignment: .trailing)
                    SortHeader(title: "STATUS", key: .status, state: $sort, width: 96, alignment: .leading)
                }
                .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2)
                .background(PC.canvas).pcHairline(.bottom)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayed) { entry in
                            CacheRow(entry: entry,
                                     isSelected: selection.contains(entry.path),
                                     onRowTap: { shift in toggle(entry.path, shift: shift) },
                                     breakdown: breakdowns[entry.path],
                                     inspecting: inspectingPaths.contains(entry.path),
                                     onInspect: { onInspect(entry) })
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
                               let going = Set(selected.map(\.path))
                               onTrash(selected)
                               selection.subtract(going)
                           })
            }
        }
    }
}

struct CacheRow: View {
    let entry: CacheEntry
    let isSelected: Bool
    var onRowTap: (Bool) -> Void = { _ in }
    var breakdown: CacheBreakdown? = nil
    var inspecting: Bool = false
    var onInspect: () -> Void = {}
    @State private var hover = false
    @State private var expanded = false
    var body: some View {
        HStack(alignment: .top, spacing: PC.gutter) {
            if entry.cleanable {
                // the checkbox reflects state; the row is the hit target
                Toggle("", isOn: .constant(isSelected)).labelsHidden().toggleStyle(.checkbox)
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
            // A locked row says "Protected", never "Safe to clean". `safe` and `cleanable` are
            // independent, so the old unconditional pill could promise a green safe-to-clean
            // beside a lock icon whose tooltip said the opposite.
            Group {
                if entry.cleanable {
                    Pill(text: entry.safe ? "Safe to clean" : "Check first",
                         tint: entry.safe ? PC.green : PC.amber,
                         soft: entry.safe ? PC.greenSoft : PC.amberSoft)
                } else {
                    Pill(text: "Protected", tint: PC.meta, soft: PC.chip)
                }
            }
            .frame(width: 96, alignment: .leading)
            Button {
                expanded.toggle()
                if expanded { onInspect() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hover || expanded ? PC.ink2 : PC.meta.opacity(0.5))
                    .frame(width: 14)
            }
            .buttonStyle(.plain).help("Where this size comes from")
        }
        .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2 + 1)
        .background(isSelected ? PC.fill2 : (hover ? PC.fill1.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            guard entry.cleanable else { return }
            onRowTap(NSEvent.modifierFlags.contains(.shift))
        }
        .onHover { hover = $0 }
        .help(entry.cleanable ? "Click to select. Shift-click to select a range."
                              : "Not on the cleaner's allowlist — Performac will not trash this.")

        if expanded { detail }
    }

    /// What the size is made of, and what refills it.
    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: PC.s2) {
            if let origin = CacheDetail.origin(forID: entry.cacheID) {
                Text(origin).font(.pcSmall).foregroundStyle(PC.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if inspecting {
                HStack(spacing: PC.s2) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Measuring what is inside…").font(.pcSmall).foregroundStyle(PC.meta)
                }
            } else if let b = breakdown {
                if b.parts.isEmpty {
                    Text("Nothing inside it right now.").font(.pcSmall).foregroundStyle(PC.meta)
                } else {
                    ForEach(b.parts) { part in
                        HStack(spacing: PC.s2) {
                            Text(part.name).font(.pcSmall).foregroundStyle(PC.ink).lineLimit(1)
                            Spacer(minLength: PC.s2)
                            if part.files > 0 {
                                Text("\(Fmt.count(part.files)) files")
                                    .font(.pcNum).foregroundStyle(PC.meta)
                            }
                            Text(Fmt.bytes(part.bytes)).font(.pcNum).foregroundStyle(PC.ink)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                    if let ext = b.mainExtension {
                        Text("Mostly .\(ext) files.").font(.pcSmall).foregroundStyle(PC.meta)
                    }
                }
            }
        }
        .padding(.leading, PC.stack + PC.gutter).padding(.trailing, PC.gutter)
        .padding(.vertical, PC.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PC.fill1.opacity(0.5))
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

            // Scrolls, and capped. An unbounded list grew the sheet past the screen once you
            // selected enough caches, taking Cancel and the confirm button with it.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { i in
                        HStack(alignment: .top, spacing: PC.gutter) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(i.name).font(.pcBody).foregroundStyle(PC.ink)
                                Text(i.path).font(.pcSmall).foregroundStyle(PC.meta).lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(Fmt.bytes(i.bytes)).font(.pcNum).foregroundStyle(PC.ink)
                        }
                        .padding(.horizontal, 24).padding(.vertical, PC.s2)
                    }
                }
            }
            .frame(maxHeight: 260)

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
