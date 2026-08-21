// AppsView.swift — uninstall an app and the state it scattered around ~/Library.
// Two panes: apps by size on the left, what removing one would take on the right.
import SwiftUI

struct AppsView: View {
    var apps: [InstalledApp] = []
    var selected: InstalledApp? = nil
    var leftovers: [Leftover] = []
    var refusal: String? = nil
    var appsLoading: Bool = false
    var leftoversLoading: Bool = false
    var onAppear: () -> Void = {}
    var onSelect: (InstalledApp) -> Void = { _ in }
    var onToggle: (Int, Bool) -> Void = { _, _ in }
    var onUninstall: () -> Void = {}
    @State private var confirming = false

    private var reclaim: Int64 {
        (selected?.bytes ?? 0) + leftovers.filter(\.selected).reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        Page(title: "Apps",
             subtitle: "Remove an app together with the files it leaves behind. Everything goes to the Trash.") {
            HSplitView {
                VStack(spacing: 0) {
                if appsLoading {
                    HStack(spacing: PC.s2) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("Measuring app sizes…").font(.pcSmall).foregroundStyle(PC.meta)
                        Spacer()
                    }
                    .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2)
                    .background(PC.fill1).pcHairline(.bottom)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(apps) { app in
                            AppRow(app: app, isSelected: selected?.id == app.id) { onSelect(app) }
                            Divider().overlay(PC.hairline)
                        }
                    }
                }
                }
                .frame(minWidth: 260, idealWidth: 340)
                .background(PC.surface)

                Group {
                    if let app = selected {
                        detail(app)
                    } else {
                        VStack(spacing: PC.s2) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 30)).foregroundStyle(PC.meta)
                            Text("Pick an app to see what removing it would take.")
                                .font(.pcBody).foregroundStyle(PC.ink2)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 340)
                .background(PC.canvas)
            }
        }
        .onAppear(perform: onAppear)
    }

    @ViewBuilder private func detail(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PC.gutter) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.pcHeadline).foregroundStyle(PC.ink)
                    Text(app.bundleID).font(.pcSmall).foregroundStyle(PC.meta)
                }
                Spacer()
                Text(Fmt.bytes(app.bytes)).font(.pcNumLg).foregroundStyle(PC.ink)
            }
            .padding(PC.stack).pcHairline(.bottom)

            if let refusal {
                HStack(alignment: .top, spacing: PC.s2) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(PC.amber)
                    Text(refusal).font(.pcBody).foregroundStyle(PC.ink2)
                }
                .padding(PC.stack)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: PC.s2) {
                        HStack(spacing: PC.s2) {
                            SectionHeader(text: leftoversLoading ? "Left behind" : "Left behind (\(leftovers.count))")
                            if leftoversLoading { ProgressView().controlSize(.small).scaleEffect(0.6) }
                            Spacer()
                        }
                        .padding(.horizontal, PC.stack).padding(.top, PC.gutter)
                        if leftovers.isEmpty && !leftoversLoading {
                            Text("Nothing else found under ~/Library.")
                                .font(.pcSmall).foregroundStyle(PC.meta)
                                .padding(.horizontal, PC.stack)
                        }
                        ForEach(Array(leftovers.enumerated()), id: \.element.id) { i, l in
                            HStack(alignment: .top, spacing: PC.s2) {
                                Toggle("", isOn: Binding(get: { l.selected },
                                                         set: { onToggle(i, $0) }))
                                    .labelsHidden().toggleStyle(.checkbox)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: PC.s1) {
                                        Text(l.category).font(.pcLabel).foregroundStyle(PC.meta)
                                        if !l.byBundleID {
                                            Pill(text: "name match", tint: PC.amber, soft: PC.amberSoft)
                                        }
                                    }
                                    Text(l.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .font(.pcSmall).foregroundStyle(PC.ink2)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: PC.s2)
                                Text(Fmt.bytes(l.bytes)).font(.pcNum).foregroundStyle(PC.ink)
                            }
                            .padding(.horizontal, PC.stack).padding(.vertical, 5)
                        }
                    }
                    .padding(.bottom, PC.stack)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Reclaims \(Fmt.bytes(reclaim))").font(.pcTitle).foregroundStyle(PC.ink)
                        Text("Everything goes to the Trash and stays recoverable.")
                            .font(.pcSmall).foregroundStyle(PC.meta)
                    }
                    Spacer()
                    Button("Move to Trash") { confirming = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, PC.stack).padding(.vertical, PC.gutter)
                .background(PC.surface).pcHairline(.top)
            }
        }
        .sheet(isPresented: $confirming) {
            UninstallSheet(app: app, items: leftovers.filter(\.selected), total: reclaim,
                           onCancel: { confirming = false },
                           onConfirm: { confirming = false; onUninstall() })
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let isSelected: Bool
    let onTap: () -> Void
    var body: some View {
        HStack(spacing: PC.s2) {
            Image(systemName: app.isSystem ? "lock.fill" : "app.fill")
                .font(.system(size: 11))
                .foregroundStyle(app.isSystem ? PC.meta : PC.accent)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.name).font(.pcBody).foregroundStyle(PC.ink).lineLimit(1)
                if app.isRunning {
                    Text("running").font(.pcLabel).foregroundStyle(PC.amber)
                }
            }
            Spacer(minLength: PC.s2)
            if app.bytes > 0 {
                Text(Fmt.bytes(app.bytes)).font(.pcNum).foregroundStyle(PC.ink2)
            } else {
                Text("—").font(.pcNum).foregroundStyle(PC.meta.opacity(0.5))
            }
        }
        .padding(.horizontal, PC.gutter).padding(.vertical, 6)
        .background(isSelected ? PC.fill2 : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// Uninstalling removes more than the app, so the sheet lists every path by name.
struct UninstallSheet: View {
    let app: InstalledApp
    let items: [Leftover]
    let total: Int64
    var onCancel: () -> Void
    var onConfirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Remove \(app.name) and \(items.count) leftover item\(items.count == 1 ? "" : "s")?")
                .font(.pcHeadline).foregroundStyle(PC.ink)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, PC.gutter)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.path).font(.pcSmall).foregroundStyle(PC.ink)
                    ForEach(items) { i in
                        Text(i.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.pcSmall).foregroundStyle(PC.ink2)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
            }
            .frame(maxHeight: 190)
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
        .frame(width: 560)
        .pcGlassPanel(PC.rXl)
    }
}
