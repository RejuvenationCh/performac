// Check/CheckHarness.swift — the assert-based check pattern (CommandLineTools ships
// neither swift-testing nor XCTest). Every ported v1 test becomes one check() here;
// `Performac check` runs all suites and reports the total.
import Foundation

@MainActor
final class CheckSuite {
    private(set) var passed = 0
    private(set) var failed = 0

    func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        if cond {
            passed += 1
            print("PASS \(name)")
        } else {
            failed += 1
            print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    func eq<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        check(name, actual == expected, "got \(actual), want \(expected)")
    }

    func true_(_ name: String, _ cond: Bool, _ detail: String = "") {
        check(name, cond, detail)
    }

    func false_(_ name: String, _ cond: Bool, _ detail: String = "") {
        check(name, !cond, detail.isEmpty ? "" : detail)
    }
}

let ALL_CHECK_SUITES: [(String, @MainActor (CheckSuite) async -> Void)] = [
    ("CollectorsCheck", { c in await CollectorsCheck.run(c) }),
    ("ConfigCheck", { c in await ConfigCheck.run(c) }),
    ("DatabaseCheck", { c in await DatabaseCheck.run(c) }),
    ("PathsCheck", { c in await PathsCheck.run(c) }),
    ("RulesCheck", { c in await RulesCheck.run(c) }),
    ("CleanCheck", { c in await CleanCheck.run(c) }),
    ("DupCheck", { c in await DupCheck.run(c) }),
    ("FileKindCheck", { c in await FileKindCheck.run(c) }),
    ("ProcessCheck", { c in await ProcessCheck.run(c) }),
    ("CopyCheckTests", { c in await CopyCheckTests.run(c) }),
    ("AppearanceCheck", { c in await AppearanceCheck.run(c) }),
    ("StorageBarCheck", { c in await StorageBarCheck.run(c) }),
    ("VolumeCheck", { c in await VolumeCheck.run(c) }),
    ("SamplerCheck", { c in await SamplerCheck.run(c) }),
    ("NotifyCheck", { c in await NotifyCheck.run(c) }),
]

@MainActor
func runAllChecks() async -> Int32 {
    let suite = CheckSuite()
    for (name, run) in ALL_CHECK_SUITES {
        print("=== \(name) ===")
        await run(suite)
    }
    print("=== \(suite.passed) passed, \(suite.failed) failed ===")
    return suite.failed == 0 ? 0 : 1
}
