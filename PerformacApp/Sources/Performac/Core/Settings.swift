// Core/Settings.swift: Phase 0 settings.
//
// launchAtLogin defaults to OFF on purpose: SMAppService registration belongs at the
// Phase 4 cutover. A half-built app auto-starting at login is a nuisance, and v1's
// LaunchAgent still owns sampling until then.
struct Settings {
    static let launchAtLogin = false

    /// Called at startup; a no-op until Phase 4 flips launchAtLogin on.
    static func registerLaunchAtLoginIfEnabled() {
        guard launchAtLogin else { return }
        // Phase 4 cutover: the app registers itself, no LaunchAgent plist.
        // try? SMAppService.mainApp.register()
    }
}
