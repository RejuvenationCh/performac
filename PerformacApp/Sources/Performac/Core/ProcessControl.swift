// ProcessControl.swift — the ONLY place this app terminates anything.
//
// Two stages, deliberately. `quit` sends a real quit request (the same one Cmd-Q sends), so
// an app with unsaved work gets to prompt you and save it. `force` is a separate, explicit
// escalation for when that is ignored — it kills immediately and unsaved work is lost.
//
// Never offered for anything the system needs: root-owned processes, low PIDs, and a
// denylist of things whose death takes the session with them.
import AppKit
import Foundation

enum ProcessControl {
    /// Killing these either logs you out, freezes the UI, or panics the machine.
    static let protected: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "SystemUIServer",
        "Dock", "Finder", "coreaudiod", "hidd", "mds", "mds_stores", "opendirectoryd",
        "securityd", "syslogd", "distnoted", "cfprefsd", "backupd", "Performac",
    ]

    struct Target: Sendable {
        var pid: Int32
        var name: String
        var isApp: Bool          // has a GUI app to ask politely
        var hasWindows: Bool     // likely holds unsaved work
    }

    enum Refusal: String, Error, Sendable {
        case systemCritical = "This process is part of macOS — quitting it would end your session."
        case notYours = "Owned by another user or by root, so Performac will not touch it."
        case gone = "That process is no longer running."
    }

    /// Look up a live process by name. Returns nil when there is nothing safe to offer.
    static func target(named name: String) -> Result<Target, Refusal> {
        if protected.contains(name) { return .failure(.systemCritical) }
        let apps = NSWorkspace.shared.runningApplications
        if let app = apps.first(where: { $0.localizedName == name || $0.bundleURL?.deletingPathExtension().lastPathComponent == name }) {
            if app.processIdentifier < 100 { return .failure(.systemCritical) }
            return .success(Target(pid: app.processIdentifier, name: app.localizedName ?? name,
                                   isApp: true, hasWindows: app.activationPolicy == .regular))
        }
        guard let pid = pidForName(name) else { return .failure(.gone) }
        if pid < 100 { return .failure(.systemCritical) }
        guard ownedByCurrentUser(pid) else { return .failure(.notYours) }
        return .success(Target(pid: pid, name: name, isApp: false, hasWindows: false))
    }

    /// Stage one: ask. A GUI app can refuse and prompt you to save.
    @discardableResult
    static func quit(_ t: Target) -> Bool {
        if t.isApp, let app = NSRunningApplication(processIdentifier: t.pid) {
            return app.terminate()
        }
        return kill(t.pid, SIGTERM) == 0
    }

    /// Stage two: an explicit escalation, offered only after `quit` was ignored.
    /// Unsaved work is lost. Never called without the user asking a second time.
    @discardableResult
    static func force(_ t: Target) -> Bool {
        if t.isApp, let app = NSRunningApplication(processIdentifier: t.pid) {
            return app.forceTerminate()
        }
        return kill(t.pid, SIGKILL) == 0
    }

    static func isRunning(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    // MARK: helpers

    static func pidForName(_ name: String) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", name]                     // exact name, argv array, no shell
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n").first.flatMap { Int32($0) }
    }

    static func ownedByCurrentUser(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_eproc.e_ucred.cr_uid == getuid()
    }
}
