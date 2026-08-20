// AppDelegate.swift — the shell: a status item that states the worst finding, a popover for
// the glance, and a window for the work. LSUIElement, so no Dock icon unless the window opens.
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Light only, by user decision — the app does not follow the system appearance.
        // Every token in Tokens.swift still carries a dark value, so dropping this line
        // is all that is needed to restore automatic light/dark.
        NSApp.appearance = NSAppearance(named: .aqua)

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

    /// The title states the most severe finding, or stays a bare glyph when all is quiet.
    private func configureStatusButton() {
        guard let b = statusItem.button else { return }
        let worst = Sample.findings.first { $0.severity == .red }
            ?? Sample.findings.first { $0.severity == .amber }
        b.image = NSImage(systemSymbolName: worst == nil ? "gauge.with.dots.needle.33percent"
                                                         : "exclamationmark.triangle.fill",
                          accessibilityDescription: "Performac")
        b.image?.isTemplate = true
        b.imagePosition = .imageLeading
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.title = worst == nil ? "" : " T7 flapped 2×"
        b.toolTip = worst?.headline ?? "Performac — nothing worth doing"
        b.target = self
        b.action = #selector(togglePopover)
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
