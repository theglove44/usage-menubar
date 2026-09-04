// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "UsageMenuBar",
            path: "Sources/UsageMenuBar",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "UsageMenuBarTests",
            dependencies: ["UsageMenuBar"]
        )
    ],
    // Tools version 6.0 is required for the Swift Testing framework (the only
    // test framework the Command Line Tools ship). The sources stay in Swift 5
    // language mode: Swift 6's strict concurrency rules would reject the
    // existing Timer-based code, and this port is about the test framework
    // only, not a concurrency migration.
    swiftLanguageModes: [.v5]
)
