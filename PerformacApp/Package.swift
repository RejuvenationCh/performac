// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Performac",
    platforms: [.macOS(.v15)],   // SwiftPM enum has no .v26; the toolchain still targets macOS 26
    targets: [
        // NOTE: no testTarget — CommandLineTools ships neither swift-testing nor
        // XCTest modules. Checks live in `Performac check` (see ScannerSelfCheck.swift).
        .executableTarget(
            name: "Performac",
            path: "Sources/Performac",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
