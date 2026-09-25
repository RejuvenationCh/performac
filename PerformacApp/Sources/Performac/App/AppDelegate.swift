// AppDelegate.swift, the shell: a window for the work, and nothing else. Regular
// activation policy: Dock icon, no menu bar item.
//
// Phase 1 wiring: owns the EngineStore, boots the Sampler with real deps, schedules the
// tick/hourly loops off the main actor, and stops everything on quit so the child
// processes never outlive the app.
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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

        // A windowed app opens its window on launch.
        openWindow()
    }

    // MARK: engine, off-main sampling loops, main-actor store refreshes

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
        // Update check: the loop wakes hourly because the app rarely quits, and checkIfDue
        // itself holds it to once a day.
        engineTasks.append(Task { @MainActor in
            while !Task.isCancelled {
                await UpdateChecker.shared.checkIfDue()
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

        // Settings has six text fields and file paths use .textSelection(.enabled); without
        // this menu Cmd-C/V/X/A had no route to the first responder and silently did nothing.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

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
            // Only the Disk browser has back/forward history to navigate. Without this,
            // a horizontal swipe on Dashboard/Digest/Settings silently rewrote Disk's
            // history, and swallowing every .swipe broke horizontal scrolling everywhere.
            guard let self, self.window?.isKeyWindow == true, self.store.route == .disk else { return event }
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

    /// Never quit just because the window closed. The engine is the app: the sampler must
    /// keep running so history keeps accruing, and the Dock icon is the way back in.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Remembered so Restore Size can put it back where it was.
    private var preFillFrame: NSRect?

    /// Double-clicking the title bar (and the green button's zoom) asks the delegate what
    /// "standard size" means. AppKit's default leaves gaps; Fill Screen is what people
    /// actually expect from a maximise, so make zoom mean exactly that.
    ///
    /// This routes through the system setting rather than around it: if the user has set
    /// double-click to Minimize or Do Nothing, that still wins: we only define what
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

    func openWindow() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        // No .fullSizeContentView. It put the SwiftUI content across the whole window
        // including the titlebar strip, which swallowed double-clicks there, so the system's
        // "double-click the title bar to zoom" never reached windowWillUseStandardFrame below.
        // It also forced the rail to carry a 28pt top pad to dodge the traffic lights. Letting
        // AppKit own a real titlebar restores the gesture for free and drops the workaround.
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
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
