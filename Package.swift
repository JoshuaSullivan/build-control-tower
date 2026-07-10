// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BuildControlTower",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Official MCP Swift SDK. Pinned to the current minor so a pre-1.0
        // API change can't silently break the build on `swift package update`.
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            .upToNextMinor(from: "0.12.1")
        )
    ],
    targets: [
        .executableTarget(
            name: "BuildControlTower",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "BuildControlTowerTests",
            dependencies: ["BuildControlTower"]
        )
    ]
)
