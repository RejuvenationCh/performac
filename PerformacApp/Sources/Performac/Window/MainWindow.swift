// MainWindow.swift — 64pt icon rail + content. The rail is the ONLY navigation
// (DESIGN.md §Do not carry over: no competing top tabs).
import SwiftUI

enum Route: String, CaseIterable, Identifiable {
    case today, digest, disk, clean, duplicates, settings
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .today: "sparkles"; case .digest: "text.alignleft"; case .disk: "internaldrive"
        case .clean: "trash"; case .duplicates: "doc.on.doc"; case .settings: "gearshape"
        }
    }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

struct MainWindow: View {
    @ObservedObject var store = EngineStore.shared
    @State private var route: Route = .today
    var body: some View {
        HStack(spacing: 0) {
            Rail(route: $route)
            Group {
                switch route {
                case .today: TodayView(findings: store.live, quitAction: { store.requestQuit($0) })
                case .digest: DigestView(findings: store.digest, quitAction: { store.requestQuit($0) })
                case .disk: DiskView(
                    entries: store.diskEntries,
                    scanning: store.scanning,
                    scanFiles: store.scanFiles,
                    scanBytes: store.scanBytes,
                    scanElapsed: store.scanElapsed,
                    scanPath: store.scanPath,
                    onScan: { store.startDiskScan() },
                    lastScanAt: store.lastScanAt,
                    autoRefresh: store.autoRefreshScan,
                    onToggleAutoRefresh: { store.setAutoRefreshScan($0) },
                    onAppear: { store.diskViewAppeared() },
                    onDisappear: { store.diskViewDisappeared() },
                    scanRoot: store.scanRoot,
                    targets: store.scanTargets,
                    onPickRoot: { store.setScanRoot($0) },
                    onCancel: { store.cancelDiskScan() })
                case .clean: CleanView(caches: store.cacheEntries, onTrash: { store.trashSelected($0) })
                case .duplicates: DuplicatesView(
                    groups: store.dupGroups,
                    scanning: store.dupScanning,
                    hashed: store.dupHashed,
                    candidates: store.dupCandidates,
                    currentPath: store.dupPath,
                    onScan: { store.startDupScan() },
                    onCancel: { store.cancelDupScan() },
                    onDisappear: { store.cancelDupScan() })
                case .settings: SettingsView(
                    config: store.config,
                    fdaGranted: store.fdaGranted,
                    onSave: { key, value in _ = store.saveSetting(key, value) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PC.canvas)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

private struct Rail: View {
    @Binding var route: Route
    var body: some View {
        VStack(spacing: PC.s1) {
            Text("P").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(PC.accentFill, in: RoundedRectangle(cornerRadius: PC.rLg))
                .padding(.top, PC.gutter).padding(.bottom, PC.s2)
            ForEach(Route.allCases) { r in
                RailButton(route: r, selected: route == r) { route = r }
            }
            Spacer()
        }
        .frame(width: PC.rail)
        .frame(maxHeight: .infinity)
        .background(PC.surface)
        .pcHairline(.trailing)
    }
}

private struct RailButton: View {
    let route: Route, selected: Bool, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: route.symbol).font(.system(size: 16, weight: .regular))
                Text(route.title).font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(selected ? PC.accent : PC.meta)
            .frame(width: 52, height: 44)
            .background(selected ? PC.fill1 : (hover ? PC.fill1.opacity(0.6) : .clear),
                        in: RoundedRectangle(cornerRadius: PC.rLg))
        }
        .buttonStyle(.plain).help(route.title)
        .onHover { hover = $0 }
    }
}

/// Shared page chrome: title row above content.
struct Page<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.pcDisplay).foregroundStyle(PC.ink)
                    if let subtitle { Text(subtitle).font(.pcSmall).foregroundStyle(PC.ink2) }
                }
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, PC.stack).padding(.top, PC.stack).padding(.bottom, PC.gutter)
            content
        }
    }
}
