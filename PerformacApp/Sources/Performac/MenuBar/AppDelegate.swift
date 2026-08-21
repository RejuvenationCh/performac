// AppDelegate.swift — the shell: a status item that states the worst finding, a popover for
// the glance, and a window for the work. Regular activation policy: Dock icon + menu bar item.
//
// Phase 1 wiring: owns the EngineStore, boots the Sampler with real deps, schedules the
// tick/hourly loops off the main actor, and stops everything on quit so the child
// processes never outlive the app.
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?

    let store = EngineStore.shared
    // kept so a manual refresh can re-run the same ticks the schedulers do
    private var engineCfg: Config?
    private var engineDeps: LiveDeps?
    private var engineSampler: Sampler?
    private var metricsTimer: Timer?
    private var engineTasks: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Light only, by user decision — the app does not follow the system appearance.
        // Every token in Tokens.swift still carries a dark value, so dropping this line
        // is all that is needed to restore automatic light/dark.
        NSApp.appearance = NSAppearance(named: .aqua)

        startEngine()

        installMainMenu()
        startMetricsTimer()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(onOpenWindow: { [weak self] in self?.openWindow() })
        )

        // Dev builds open the window on launch: on a notched MacBook with a full menu bar
        // the status item can be pushed under the notch and become unreachable, and there
        // would then be no way to see the UI at all. Gate this behind a setting at Phase 4.
        openWindow()
    }

    // MARK: engine — off-main sampling loops, main-actor store refreshes

    private func startEngine() {
        let db = store.db
        let cfg = loadConfig(db)
        let deps = LiveDeps()
        let sampler = Sampler(db: db, cfg: cfg, deps: deps)
        store.sampler = sampler
        engineCfg = cfg; engineDeps = deps; engineSampler = sampler
        let store = store

        // 30s tick: samples + streams + refreshFindings (rules + findings table + notify)
        engineTasks.append(Task.detached(priority: .utility) { [sampler, store] in
            while !Task.isCancelled {
                await sampler.tick()
                await MainActor.run { store.refreshFromDatabase() }
                try? await Task.sleep(for: .seconds(Double(cfg.tickSec)))
            }
        })
        // 5min disk tick
        engineTasks.append(Task.detached(priority: .utility) { [sampler, store] in
            while !Task.isCancelled {
                await sampler.diskTick()
                try? await Task.sleep(for: .seconds(Double(cfg.diskTickSec)))
            }
        })
        // hourly: caches, backup state, drift walk, retention sweep, digest ping
        engineTasks.append(Task.detached(priority: .utility) { [sampler, store] in
            while !Task.isCancelled {
                await cacheTick(db, cfg, deps)
                await backupTick(db, cfg, deps)
                await loginTick(db, deps)
                trashTick(db)
                await driftTick(db, cfg, deps)
                sweep(db, cfg, deps.now())
                await mondayDigestCheck(db, cfg, deps.now(), { bin, args in try await deps.execFile(bin, args) })
                await MainActor.run { store.refreshFromDatabase() }
                try? await Task.sleep(for: .seconds(3600))
            }
        })
        // daily: battery (tier3-gated inside)
        engineTasks.append(Task.detached(priority: .utility) { [sampler, store] in
            while !Task.isCancelled {
                await batteryTick(db, cfg, deps)
                try? await Task.sleep(for: .seconds(86_400))
            }
        })

        // first refresh so the UI has real data before the first tick lands
        Task { [store] in
            await MainActor.run { store.refreshFromDatabase() }
        }
    }

    /// Manual refresh: re-run the measurement ticks, not just re-read the table. A refresh
    /// that only re-reads would report the same numbers and look broken.
    func refreshNow() {
        guard let cfg = engineCfg, let deps = engineDeps, let sampler = engineSampler else { return }
        let db = store.db
        let store = store
        store.refreshing = true
        Task.detached(priority: .userInitiated) {
            await sampler.tick()
            await cacheTick(db, cfg, deps)
            await backupTick(db, cfg, deps)
            await loginTick(db, deps)
            trashTick(db)
            await driftTick(db, cfg, deps)
            await refreshFindings(db, loadConfig(db), deps.now(), { b, a in try await deps.execFile(b, a) })
            await MainActor.run { store.refreshFromDatabase(); store.refreshing = false }
        }
    }

    /// Clicking the Dock icon (or the pinned tile) must bring the window back. Without this
    /// a closed window was unrecoverable without quitting and relaunching.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow() }
        return true
    }

    /// A regular app with no main menu has no Quit and no Cmd-W. Build a minimal one.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Performac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Performac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Performac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        main.addItem(winItem)
        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.sampler?.stop()
        store.cancelDiskScan()
        for t in engineTasks { t.cancel() }
    }

    /// Stats-style live readout. Two seconds is frequent enough to feel live and cheap
    /// enough to ignore: each sample is three kernel calls, no subprocess.
    private func startMetricsTimer() {
        _ = LiveMetrics.shared.cpu()          // prime the tick delta so the first read is real
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.store.metrics = LiveMetrics.shared.sample()
                self.updateStatusTitle()
            }
        }
        RunLoop.main.add(t, forMode: .common)  // keeps ticking while menus are open
        metricsTimer = t
    }

    /// What the menu bar shows, per the Settings picker: the live numbers, or the worst
    /// finding, or just free space.
    private func updateStatusTitle() {
        guard let b = statusItem?.button else { return }
        let m = store.metrics
        let mode = getSetting(store.db, "menuBarShows")?.objectVal?["mode"]?.stringVal ?? "metrics"
        let worst = store.worst

        switch mode {
        case "finding":
            b.image = NSImage(systemSymbolName: worst == nil ? "gauge.with.dots.needle.33percent"
                                                             : worst!.severity.symbol,
                              accessibilityDescription: "Performac")
            b.image?.isTemplate = true
            b.title = worst == nil ? "" : " " + shortHeadline(worst!.headline)
        case "free":
            b.image = nil
            b.title = String(format: "%.0f GB", m.freeGb)
        default:                                   // live metrics, the Stats-like default
            b.image = nil
            b.title = String(format: "%.0f%%  %.0f%%", m.cpuPercent, m.memPercent)
        }
        b.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        b.toolTip = String(format: "CPU %.0f%%   Memory %.1f of %.0f GB   Free %.0f GB   %@",
                           m.cpuPercent, m.memUsedGb, m.memTotalGb, m.freeGb, m.thermal)
            + (worst.map { "\n\n" + $0.headline } ?? "")
    }

    /// Menu bar space is scarce: keep the first few words, never the whole sentence.
    private func shortHeadline(_ h: String) -> String {
        let words = h.split(separator: " ").prefix(4).joined(separator: " ")
        return words.count > 26 ? String(words.prefix(26)) + "…" : words
    }

    /// The title states the most severe finding, or stays a bare glyph when all is quiet.
    private func configureStatusButton() {
        guard let b = statusItem.button else { return }
        b.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                          accessibilityDescription: "Performac")
        b.image?.isTemplate = true
        b.imagePosition = .imageLeading
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.title = ""
        b.toolTip = "Performac — nothing worth doing"
        b.target = self
        b.action = #selector(togglePopover)
        // live observation: severity icon + worst-finding title, quiet → bare glyph
        Task { [weak self, store] in
            for await _ in store.$live.values {
                guard let self else { return }
                await MainActor.run {
                    let worst = store.worst
                    self.statusItem.button?.image = NSImage(systemSymbolName: worst == nil
                        ? "gauge.with.dots.needle.33percent" : "exclamationmark.triangle.fill",
                        accessibilityDescription: "Performac")
                    self.statusItem.button?.image?.isTemplate = true
                    self.statusItem.button?.title = store.worstTitle
                    self.statusItem.button?.toolTip = worst?.headline ?? "Performac — nothing worth doing"
                }
            }
        }
    }

    @objc private func togglePopover() {
        guard let b = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func openWindow() {
        popover.performClose(nil)
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Performac"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: MainWindow())
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
