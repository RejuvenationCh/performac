// DiskView.swift — replaces OmniDiskSweeper (drill-down list) and GrandPerspective (treemap).
// Layout follows the Stitch artifact: breadcrumb + storage bar above a 60/40 split.
import SwiftUI
import AppKit

struct DiskView: View {
    var entries: [SizeEntry] = Sample.disk
    var scanning: Bool = false
    var scanFiles: Int = 0
    var scanBytes: Int64 = 0
    var scanElapsed: TimeInterval = 0
    var scanPath: String = ""
    var onScan: () -> Void = {}
    var lastScanAt: Int64? = nil
    var autoRefresh: Bool = false
    var onToggleAutoRefresh: (Bool) -> Void = { _ in }
    var onAppear: () -> Void = {}
    var onDisappear: () -> Void = {}
    var scanRoot: String = NSHomeDirectory()
    var targets: [(label: String, path: String)] = []
    var onPickRoot: (String) -> Void = { _ in }
    var crumbs: [(name: String, path: String)] = []
    var onOpen: (String) -> Void = { _ in }
    var onCrumb: (String) -> Void = { _ in }
    var mode: DiskViewMode = .outline
    var onMode: (DiskViewMode) -> Void = { _ in }
    var childrenOf: (String) -> [SizeEntry] = { _ in [] }
    var browsePath: String = ""
    var onReveal: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    private var maxBytes: Int64 { entries.map(\.bytes).max() ?? 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PC.gutter) {
                ScanTargetPicker(root: scanRoot, targets: targets, onPick: onPickRoot)
                if scanning {
                    Button("Cancel", action: onCancel).controlSize(.large)
                } else {
                    Button {
                        onScan()
                    } label: {
                        Label(entries.isEmpty ? "Scan" : "Rescan", systemImage: "magnifyingglass")
                            .font(.pcTitle)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Scan the selected location. Cmd-R")
                }
                Spacer()
                Picker("", selection: Binding(get: { mode }, set: onMode)) {
                    ForEach(DiskViewMode.allCases, id: \.self) { m in
                        Image(systemName: m.symbol).help(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                StorageBar(freeBytes: 70_866_000_000, totalBytes: 1_068_000_000_000)
            }
            .padding(.horizontal, PC.stack).padding(.vertical, PC.gutter)
            .background(PC.surface).pcHairline(.bottom)

            if !crumbs.isEmpty {
                CrumbBar(crumbs: crumbs, onCrumb: onCrumb)
            }
            if scanning {
                ScanProgress(files: scanFiles, bytes: scanBytes, elapsed: scanElapsed,
                             currentPath: scanPath, onCancel: onCancel)
            } else if let at = lastScanAt, !entries.isEmpty {
                StaleBanner(at: at)
            }

            HSplitView {
                VStack(spacing: 0) {
                    if mode == .outline || mode == .list {
                    HStack(spacing: PC.gutter) {
                        Text("NAME").font(.pcLabel).foregroundStyle(PC.meta)
                        Spacer()
                        Text("ITEMS").font(.pcLabel).foregroundStyle(PC.meta).frame(width: 64, alignment: .trailing)
                        Text("SIZE").font(.pcLabel).foregroundStyle(PC.meta).frame(width: 72, alignment: .trailing)
                        Text("PROPORTION").font(.pcLabel).foregroundStyle(PC.meta).frame(width: 90, alignment: .leading)
                    }
                    .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2)
                    .background(PC.canvas).pcHairline(.bottom)
                    }

                    switch mode {
                    case .outline:
                        OutlineList(entries: entries, basePath: browsePath,
                                    loadChildren: childrenOf, onReveal: onReveal)
                    case .list:
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(entries) { e in
                                    SizeRow(entry: e, maxBytes: maxBytes, onOpen: { onOpen(e.name) })
                                    Divider().overlay(PC.hairline)
                                }
                            }
                        }
                    case .compact:
                        CompactList(entries: entries, onOpen: onOpen)
                    case .bubbles:
                        BubbleView(entries: entries, onOpen: onOpen)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: PC.gutter) {
                        Text("\(entries.count) items").font(.pcSmall).foregroundStyle(PC.meta)
                        Spacer()
                        // Only offered once a scan exists: before that there is nothing to
                        // keep fresh, and the choice would be meaningless.
                        if lastScanAt != nil {
                            Toggle("Always refresh on open", isOn: Binding(
                                get: { autoRefresh }, set: onToggleAutoRefresh))
                                .toggleStyle(.checkbox).font(.pcSmall).foregroundStyle(PC.ink2)
                                .help("Rescan every time this view opens. A full scan is minutes of disk activity.")
                        }
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
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
    }
}

/// Persisted results are shown so reopening the view is not a blank screen — but they are
/// a snapshot, and the app must never let a stale number pass as a current one.
struct StaleBanner: View {
    let at: Int64
    private var age: String {
        let secs = Int(Date().timeIntervalSince1970 - Double(at) / 1000)
        if secs < 90 { return "just now" }
        if secs < 5400 { return "\(secs / 60) minutes ago" }
        if secs < 172_800 { return "\(secs / 3600) hours ago" }
        return "\(secs / 86_400) days ago"
    }
    var body: some View {
        HStack(spacing: PC.s2) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12)).foregroundStyle(PC.amber)
            Text("Showing the last scan from \(age) — not live.")
                .font(.pcSmall).foregroundStyle(PC.ink2)
            Spacer()
        }
        .padding(.horizontal, PC.stack).padding(.vertical, PC.s2)
        .background(PC.amberSoft)
        .pcHairline(.bottom)
    }
}

/// Where to scan. Home, any mounted volume (the T7 shows up here when plugged in), or any
/// folder you choose. Nothing is assumed.
struct ScanTargetPicker: View {
    let root: String
    let targets: [(label: String, path: String)]
    let onPick: (String) -> Void

    private var currentLabel: String {
        if let t = targets.first(where: { $0.path == root }) { return t.label }
        return (root as NSString).lastPathComponent
    }

    var body: some View {
        Menu {
            ForEach(targets, id: \.path) { t in
                Button {
                    onPick(t.path)
                } label: {
                    if t.path == root { Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                }
            }
            Divider()
            Button("Choose Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = "Scan"
                panel.directoryURL = URL(fileURLWithPath: root)
                if panel.runModal() == .OK, let url = panel.url { onPick(url.path) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive").font(.system(size: 12))
                Text(currentLabel).font(.pcBody).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(width: 190)
        .help(root)
    }
}

/// Live breadcrumb: every ancestor is clickable, so you can jump back up any number of
/// levels the way OmniDiskSweeper and TreeSize do.
struct CrumbBar: View {
    let crumbs: [(name: String, path: String)]
    let onCrumb: (String) -> Void
    var body: some View {
        HStack(spacing: PC.s1) {
            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(PC.meta)
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                if i > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(PC.meta)
                }
                Button(c.name) { onCrumb(c.path) }
                    .buttonStyle(.plain)
                    .font(.pcBody)
                    .fontWeight(i == crumbs.count - 1 ? .semibold : .regular)
                    .foregroundStyle(i == crumbs.count - 1 ? PC.ink : PC.accent)
            }
            Spacer()
        }
        .padding(.horizontal, PC.stack).padding(.vertical, PC.s2)
        .background(PC.canvas).pcHairline(.bottom)
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
