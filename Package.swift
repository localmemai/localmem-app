// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalMem",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "LocalMemCore", targets: ["LocalMemCore"]),
        .executable(name: "localmem", targets: ["localmem"]),
        .executable(name: "localmem-mcp", targets: ["localmem-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.0"),
    ],
    targets: [
        .target(
            name: "LocalMemCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "localmem",
            dependencies: [
                "LocalMemCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "localmem-mcp",
            dependencies: [
                "LocalMemCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "LocalMemCoreTests",
            dependencies: ["LocalMemCore"]
        ),
    ]
)
