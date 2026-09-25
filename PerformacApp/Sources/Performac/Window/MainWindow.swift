// MainWindow.swift: 76pt icon rail + content. The rail is the ONLY navigation
// (DESIGN.md §Do not carry over: no competing top tabs).
import SwiftUI
import AppKit

struct MainWindow: View {
    @ObservedObject var store = EngineStore.shared
    @ObservedObject var updates = UpdateChecker.shared
    /// Route lives in the store (see `Route` in ViewModels.swift) so a finding card's link-out
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
                    onDisableAgent: { store.disableAgent($0) },
                    trendPoints: store.trend.points,
                    trendWindow: store.trend.window,
                    trendNote: store.trend.note,
                    trendVolume: store.trend.volume)
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
                    ignorable: store.ignorableProcesses,
                    onUnignore: { store.unignoreProcess($0) },
                    onIgnore: { store.ignoreProcess($0) },
                    onSave: { key, value in _ = store.saveSetting(key, value) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PC.canvas)
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(item: $updates.offered) { r in
            UpdateSheet(release: r, current: Updates.running, ready: updates.ready,
                        onRestart: { updates.restart() }) { updates.offered = nil }
        }
    }
}

/// A newer release, with its notes. Normally already installed and waiting for a restart;
/// when it could not be installed here, it links to the release page instead.
private struct UpdateSheet: View {
    let release: Release
    let current: String?
    let ready: Bool
    var onRestart: () -> Void
    var onClose: () -> Void

    /// Inline markdown (bold, code, links) rendered; line breaks kept so a bulleted changelog
    /// still reads as a list. Falls back to the raw text if it does not parse.
    private var notes: AttributedString {
        // Inline parsing leaves "### Fixes" literal, so headings become bold lines first.
        let raw = (release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            .replacingOccurrences(of: #"(?m)^#{1,6}\s*(.+?)\s*$"#, with: "**$1**", options: .regularExpression)
        if raw.isEmpty { return AttributedString("This release has no notes.") }
        return (try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ready ? "Performac \(release.version) is installed" : "Performac \(release.version) is available")
                .font(.pcHeadline).foregroundStyle(PC.ink)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 2)
            Text(ready ? "Restart to start using it. Settings and history carry over, and the previous version is in the Trash."
                 // Not "built from source": a failed download or a signature mismatch lands here
                 // too, and the sheet cannot tell which.
                 : "\(current.map { "You have \($0). " } ?? "")It could not be installed automatically. Get it from the release page, or run the installer again.")
                .font(.pcSmall).foregroundStyle(PC.meta)
                .padding(.horizontal, 24).padding(.bottom, PC.gutter)
            ScrollView {
                Text(notes).font(.pcSmall).foregroundStyle(PC.ink2).lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PC.gutter)
            }
            .frame(maxHeight: 320).fixedSize(horizontal: false, vertical: true)
            .pcCard()
            .padding(.horizontal, 24).padding(.bottom, PC.stack)
            HStack(spacing: PC.s2 + 2) {
                Spacer()
                Button("Later", action: onClose).keyboardShortcut(.cancelAction)
                if ready {
                    Button("Restart Now", action: onRestart)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("View Release") {
                        if let u = URL(string: release.html_url) { NSWorkspace.shared.open(u) }
                        onClose()
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(width: 500)
        .pcGlassPanel(PC.rXl)
    }
}

private struct Rail: View {
    @Binding var route: Route
    var body: some View {
        VStack(spacing: PC.s1) {
            // An SF Symbol mark, not a lettermark in a coloured square: that read as the
            // most generic possible app badge and was not a control.
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(PC.accent)
                .frame(width: 28, height: 28)
                .padding(.top, PC.gutter).padding(.bottom, PC.s2)
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
            .frame(width: 64, height: 44)
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
            // canvas behind it and just rendered as a flat tint: decoration, not depth.
            .background(PC.surface)
            .pcHairline(.bottom)
            content
        }
    }
}
