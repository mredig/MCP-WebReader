// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MCP-WebReader",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .watchOS(.v9),
        .tvOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .executable(
            name: "mcp-webreader",
            targets: ["MCPWebReader"]
        ),
    ],
    dependencies: [
        // MCP Swift SDK
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
        // Swift Service Lifecycle for graceful shutdown
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.3.0"),
        // Swift Logging
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.2"),
		.package(url: "https://github.com/mredig/SwiftPizzaSnips.git", branch: "0.4.38g"),
		// HTML Parsing
		.package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
		.target(
			name: "MCPWebReaderLib",
			dependencies: [
				.product(name: "MCP", package: "swift-sdk"),
				"SwiftPizzaSnips",
				.product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
				.product(name: "Logging", package: "swift-log"),
				.product(name: "SwiftSoup", package: "SwiftSoup"),
			],
			swiftSettings: [
				.enableUpcomingFeature("StrictConcurrency")
			]
		),
        .executableTarget(
            name: "MCPWebReader",
            dependencies: [
				"MCPWebReaderLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/MCPWebReader",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MCPWebReaderTests",
            dependencies: [
				.targetItem(name: "MCPWebReaderLib", condition: nil),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Tests/MCPWebReaderTests"
        ),
    ]
)
