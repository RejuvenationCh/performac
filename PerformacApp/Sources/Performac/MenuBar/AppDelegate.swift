// MenuBar/AppDelegate.swift — Phase 0 shell: owns the status item for the app's lifetime.
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerLaunchAtLoginIfEnabled()
        statusController = StatusItemController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // menu bar app: keep running with no windows
    }
}
