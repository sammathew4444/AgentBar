// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentBar",
            path: "Sources/AgentBar"
        ),
        .testTarget(
            name: "AgentBarTests",
            dependencies: ["AgentBar"],
            path: "Tests/AgentBarTests",
            // Read from disk by path, not bundled as resources.
            exclude: ["Fixtures"]
        ),
    ]
)
