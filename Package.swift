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
        ),
        // HTTP server for the shared daemon. The SDK's HTTP transport is a
        // bring-your-own-server adapter; Hummingbird provides the listener and
        // SSE streaming. Built on swift-nio, which the MCP SDK already pulls in.
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            from: "2.0.0"
        ),
        // Both already in the graph transitively (via Hummingbird / the MCP
        // SDK); declared directly only so the HTTP bridge can name ByteBuffer
        // and HTTPFields / HTTPResponse.Status when translating requests.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "BuildControlTower",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        .testTarget(
            name: "BuildControlTowerTests",
            dependencies: ["BuildControlTower"]
        )
    ]
)
