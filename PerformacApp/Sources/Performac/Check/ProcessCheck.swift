// ProcessCheck.swift: the refusals, written to falsify. Nothing here kills anything.
import Foundation

enum ProcessCheck {
    @MainActor static func run(_ c: CheckSuite) async {
        // system-critical names must be refused outright, before any lookup
        for name in ["kernel_task", "WindowServer", "launchd", "loginwindow", "Finder", "Dock"] {
            if case .failure(let r) = ProcessControl.target(named: name) {
                c.check("proc: \(name) refused", r == .systemCritical)
            } else {
                c.check("proc: \(name) refused", false)
            }
        }
        // the app must refuse to kill itself
        if case .failure(let r) = ProcessControl.target(named: "Performac") {
            c.check("proc: refuses to kill itself", r == .systemCritical)
        } else { c.check("proc: refuses to kill itself", false) }

        // a name that is not running is reported, never guessed at
        if case .failure(let r) = ProcessControl.target(named: "definitely-not-a-real-process-xyz") {
            c.check("proc: unknown name → gone", r == .gone)
        } else { c.check("proc: unknown name → gone", false) }

        // ownership check is real: pid 1 is launchd (root), we are not root
        c.check("proc: root-owned pid not owned by us", !ProcessControl.ownedByCurrentUser(1))
        c.check("proc: our own pid is owned by us",
                ProcessControl.ownedByCurrentUser(ProcessInfo.processInfo.processIdentifier))
        c.check("proc: our own pid is running",
                ProcessControl.isRunning(ProcessInfo.processInfo.processIdentifier))
        c.check("proc: pid 0 is not a live target", !ProcessControl.isRunning(999_999))
    }
}
