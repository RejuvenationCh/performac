// AppDelegate.swift — the shell: a status item that states the worst finding, a popover for
// the glance, and a window for the work. Regular activation policy: Dock icon + menu bar item.
//
// Phase 1 wiring: owns the EngineStore, boots the Sampler with real deps, schedules the
// tick/hourly loops off the main actor, and stops everything on quit so the child
// processes never outlive the app.
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?

    let store = EngineStore.shared
    // kept so a manual refresh can re-run the same ticks the schedulers do
    private var engineCfg: Config?
    private var engineDeps: LiveDeps?
    private var engineSampler: Sampler?
    private var navMonitor: Any?
    private var engineTasks: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Light, dark, or the system's choice. Defaults to matching the system; every token
        // in Tokens.swift carries both values.
        Appearance.applyStored()

        startEngine()

        installMainMenu()
        startNavigationMonitor()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()
        // nil = inherit from the menu bar's own appearance, whatever the app is set to
        Appearance.onApply = { [weak self] in self?.statusItem.button?.appearance = nil }
        Appearance.onApply?()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                onOpenWindow: { [weak self] in self?.openWindow() },
                onScan: { [weak self] in
                    self?.openWindow()
                    EngineStore.shared.startDiskScan()
                })
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
        winMenu.addItem(.separator())
        let back = NSMenuItem(title: "Back", action: #selector(navigateBack), keyEquivalent: "[")
        back.keyEquivalentModifierMask = [.command]
        back.target = self
        winMenu.addItem(back)
        let fwd = NSMenuItem(title: "Forward", action: #selector(navigateForward), keyEquivalent: "]")
        fwd.keyEquivalentModifierMask = [.command]
        fwd.target = self
        winMenu.addItem(fwd)
        winMenu.addItem(.separator())
        // Fill the screen but stay a normal window: menu bar visible, no Space switch,
        // no animation. Option-clicking the green button "zooms", which is close but
        // leaves gaps and toggles unpredictably; this is explicit.
        let fill = NSMenuItem(title: "Fill Screen", action: #selector(fillScreen), keyEquivalent: "f")
        fill.keyEquivalentModifierMask = [.command, .option]
        fill.target = self
        winMenu.addItem(fill)
        let restore = NSMenuItem(title: "Restore Size", action: #selector(restoreSize), keyEquivalent: "f")
        restore.keyEquivalentModifierMask = [.command, .option, .shift]
        restore.target = self
        winMenu.addItem(restore)
        winMenu.addItem(.separator())
        let fs = NSMenuItem(title: "Enter Full Screen",
                            action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        winMenu.addItem(fs)
        winItem.submenu = winMenu
        main.addItem(winItem)
        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.sampler?.stop()
        store.cancelDiskScan()
        for t in engineTasks { t.cancel() }
    }

    /// The universal back/forward gestures, wired to the browse history.
    ///
    /// Two sources, because people reach for both: the mouse's side buttons (button 3 and 4,
    /// which macOS reports as otherMouseDown) and a two-finger horizontal swipe on the
    /// trackpad. Cmd-[ and Cmd-] are in the Window menu for the keyboard.
    private func startNavigationMonitor() {
        navMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            switch event.type {
            case .otherMouseDown:
                // 3 = back, 4 = forward on every multi-button mouse that reports them
                if event.buttonNumber == 3 { self.store.goBack(); return nil }
                if event.buttonNumber == 4 { self.store.goForward(); return nil }
            case .swipe:
                // deltaX is +1 for a leftward (back) swipe on a natural-scrolling trackpad
                if event.deltaX > 0 { self.store.goBack(); return nil }
                if event.deltaX < 0 { self.store.goForward(); return nil }
            default: break
            }
            return event
        }
    }

    @objc private func navigateBack() { store.goBack() }
    @objc private func navigateForward() { store.goForward() }

    /// Severity glyph always; the worst finding's first words too, when Settings asks.
    func updateStatusTitle() {
        guard let b = statusItem?.button else { return }
        let worst = store.worst
        b.image = NSImage(systemSymbolName: worst?.severity.symbol ?? "gauge.with.dots.needle.33percent",
                          accessibilityDescription: "Performac")
        b.image?.isTemplate = true
        b.title = store.menuBarItems.contains(.finding) ? worst.map { shortHeadline($0.headline) } ?? "" : ""
        b.toolTip = worst?.headline ?? "Performac — nothing worth doing"
    }

    /// Closing the window retreats to the menu bar rather than quitting: the sampler must
    /// keep running, and a background agent has no business holding a Dock tile. Reopening
    /// from the menu bar or the pinned icon promotes it back to a regular app.
    ///
    /// A pinned Dock icon stays visible either way — what disappears is the running
    /// indicator and the Cmd-Tab entry, which is correct for something with no window.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    /// Never quit just because the window closed. The engine is the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Remembered so Restore Size can put it back where it was.
    private var preFillFrame: NSRect?

    /// Double-clicking the title bar (and the green button's zoom) asks the delegate what
    /// "standard size" means. AppKit's default leaves gaps; Fill Screen is what people
    /// actually expect from a maximise, so make zoom mean exactly that.
    ///
    /// This routes through the system setting rather than around it: if the user has set
    /// double-click to Minimize or Do Nothing, that still wins — we only define what
    /// happens when it does zoom.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        guard let screen = window.screen ?? NSScreen.main else { return defaultFrame }
        // Remember the pre-zoom frame so the second double-click, and Restore Size, both
        // return to where it actually was.
        if !window.frame.equalTo(screen.visibleFrame) { preFillFrame = window.frame }
        return screen.visibleFrame
    }

    @objc private func fillScreen() {
        guard let w = window, let screen = w.screen ?? NSScreen.main else { return }
        if w.styleMask.contains(.fullScreen) { return }      // already full screen proper
        if preFillFrame == nil { preFillFrame = w.frame }
        w.setFrame(screen.visibleFrame, display: true, animate: false)
    }

    @objc private func restoreSize() {
        guard let w = window, let f = preFillFrame else { return }
        w.setFrame(f, display: true, animate: false)
        preFillFrame = nil
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
                await MainActor.run { self.updateStatusTitle() }
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
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            installMainMenu()          // the menu bar is dropped when going accessory
        }
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Performac"
        w.titlebarAppearsTransparent = true
        // Both are offered: the green button still enters macOS full screen (its own Space,
        // menu bar hidden), and Fill Screen below maximises within the current Space, which
        // is what most people actually want from a "maximise" and macOS has no button for.
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: MainWindow())
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
