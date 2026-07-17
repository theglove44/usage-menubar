// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "UsageMenuBar",
            path: "Sources/UsageMenuBar"
        ),
        .testTarget(
            name: "UsageMenuBarTests",
            dependencies: ["UsageMenuBar"]
        )
    ]
)
