// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Localmem",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "LocalmemCore", targets: ["LocalmemCore"]),
        .executable(name: "localmem", targets: ["localmem"]),
        .executable(name: "localmem-mcp", targets: ["localmem-mcp"]),
        .executable(name: "localmem-app", targets: ["localmem-app"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "LocalmemCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "localmem",
            dependencies: [
                "LocalmemCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .executableTarget(
            name: "localmem-mcp",
            dependencies: [
                "LocalmemCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "localmem-app",
            dependencies: ["LocalmemCore"],
            path: "Sources/localmem-app"
        ),
        .testTarget(
            name: "LocalmemCoreTests",
            dependencies: ["LocalmemCore"]
        ),
        .testTarget(
            name: "LocalmemMCPTests",
            dependencies: [
                "localmem-mcp",
                "LocalmemCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "LocalmemTests",
            dependencies: [
                "localmem",
                "LocalmemCore",
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .testTarget(
            name: "LocalmemAppTests",
            dependencies: ["localmem-app", "LocalmemCore"]
        ),
    ]
)
