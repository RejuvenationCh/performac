// MainWindow.swift — 64pt icon rail + content. The rail is the ONLY navigation
// (DESIGN.md §Do not carry over: no competing top tabs).
import SwiftUI
import AppKit

struct MainWindow: View {
    @ObservedObject var store = EngineStore.shared
    /// Route lives in the store (see `Route` in ViewModels.swift) so a coach card's link-out
    /// can navigate and so the choice survives the window closing.
    var body: some View {
        HStack(spacing: 0) {
            Rail(route: Binding(get: { store.route }, set: { store.route = $0 }))
            Group {
                switch store.route {
                case .overview: OverviewView(
                    findings: store.digest,
                    facts: store.quietFacts,
                    updatedAt: store.findingsAt,
                    busy: store.refreshing,
                    onRefresh: { (NSApp.delegate as? AppDelegate)?.refreshNow() },
                    quitAction: { store.requestQuit($0) },
                    onIgnore: { store.ignoreProcess($0) },
                    onLink: { store.openLink($0) },
                    coachIntro: store.coachIntro,
                    coachAt: store.coachAt,
                    coachBusy: store.coachBusy,
                    coachConfigured: store.coachConfigured,
                    onCoach: { store.refreshCoachIntro() },
                    trendPoints: store.trend.points,
                    trendWindow: store.trend.window,
                    trendNote: store.trend.note)
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
                    targetNotes: store.scanTargetNotes,
                    newDrive: store.newlyMounted,
                    onScanNewDrive: { store.scanNewDrive() },
                    onDismissNewDrive: { store.dismissNewDrive() },
                    crumbs: store.breadcrumb,
                    onOpen: { store.browse(into: $0) },
                    onCrumb: { store.browse(to: $0) },
                    canGoBack: store.canGoBack,
                    canGoForward: store.canGoForward,
                    onBack: { store.goBack() },
                    onForward: { store.goForward() },
                    mode: store.diskViewMode,
                    onMode: { store.setDiskViewMode($0) },
                    childrenOf: { store.childrenOf($0) },
                    browsePath: store.browsePath,
                    onReveal: { NSWorkspace.shared.selectFile($0, inFileViewerRootedAtPath: "") },
                    onTrashPath: { store.trashPath($0) },
                    // the volume in the picker, not always the boot disk
                    freeBytes: store.scanRootSpaceBytes.free,
                    totalBytes: store.scanRootSpaceBytes.total,
                    rightMode: store.rightPanelMode,
                    onRightMode: { store.setRightPanelMode($0) },
                    onCancel: { store.cancelDiskScan() })
                case .clean: CleanView(
                    caches: store.cacheEntries,
                    busy: store.trashing,
                    progress: store.trashProgress,
                    summary: store.lastTrashSummary,
                    breakdowns: store.breakdowns,
                    inspectingPaths: store.inspecting,
                    onInspect: { store.inspectCache($0) },
                    onTrash: { store.trashSelected($0) })
                case .duplicates: DuplicatesView(
                    groups: store.dupGroups,
                    scanning: store.dupScanning,
                    hashed: store.dupHashed,
                    candidates: store.dupCandidates,
                    currentPath: store.dupPath,
                    onScan: { store.startDupScan() },
                    onCancel: { store.cancelDupScan() },
                    onDisappear: { store.cancelDupScan() },
                    lastScanAt: store.dupScanAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                    onReveal: { NSWorkspace.shared.selectFile($0, inFileViewerRootedAtPath: "") },
                    onTrashPath: { store.trashPath($0) })
                case .settings: SettingsView(
                    config: store.config,
                    fdaGranted: store.fdaGranted,
                    databaseSummary: store.databaseSummary,
                    ignored: store.ignoredProcesses,
                    onUnignore: { store.unignoreProcess($0) },
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
            // An SF Symbol mark, not a lettermark in a coloured square — that read as the
            // most generic possible app badge and was not a control.
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(PC.accent)
                .frame(width: 28, height: 28)
                // The window uses .fullSizeContentView, so content starts at y=0 under the
                // titlebar — this clears the traffic lights instead of sitting under them.
                .padding(.top, 28).padding(.bottom, PC.s2)
            ForEach(Route.primary) { r in
                RailButton(route: r, selected: route == r) { route = r }
            }
            Spacer()
            RailButton(route: .settings, selected: route == .settings) { route = .settings }
                .padding(.bottom, PC.gutter)
        }
        .frame(width: PC.rail)
        .frame(maxHeight: .infinity)
        .pcGlassChrome()
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
                Text(route.title).font(.pcLabel)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            // Opaque, not glass: nothing scrolls under this row, so glass here had an opaque
            // canvas behind it and just rendered as a flat tint — decoration, not depth.
            .background(PC.surface)
            .pcHairline(.bottom)
            content
        }
    }
}
