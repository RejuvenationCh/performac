// MenuBar/StatusItemController.swift — NSStatusItem + popover, the primary surface.
import AppKit

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let content = PopoverViewController()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.title = "P"                 // placeholder title (Phase 0)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        content.onStatusTitle = { [weak self] title in
            self?.statusItem.button?.title = title
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {}
}
