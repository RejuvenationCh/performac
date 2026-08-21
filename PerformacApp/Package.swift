// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Performac",
    platforms: [.macOS("26.0")],   // string form: the enum has no .v26, and Liquid Glass needs it
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
