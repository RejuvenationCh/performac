// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Performac",
    platforms: [.macOS("14.0")],   // Sonoma. Liquid Glass is guarded with #available, see Tokens.swift
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
