// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PiMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PiMenuBar", targets: ["PiMenuBar"]),
        .library(name: "PiMenuBarCore", targets: ["PiMenuBarCore"]),
        .executable(name: "PiMenuBarTests", targets: ["PiMenuBarTests"]),
    ],
    targets: [
        // Foundation-only. Merge rules, registry decoding, protocol decoding and
        // title formatting live here so they can be unit tested without AppKit.
        .target(
            name: "PiMenuBarCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // AppKit shell: status item, menu, socket client, file watching, focus.
        .executableTarget(
            name: "PiMenuBar",
            dependencies: ["PiMenuBarCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Runs the suite without XCTest (see Tests/PiMenuBarTests/TestHarness.swift).
        .executableTarget(
            name: "PiMenuBarTests",
            dependencies: ["PiMenuBarCore"],
            path: "Tests/PiMenuBarTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
