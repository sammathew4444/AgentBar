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
    ]
)
