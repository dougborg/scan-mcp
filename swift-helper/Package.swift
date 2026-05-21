// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mcp-scanner-helper",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mcp-scanner-helper", targets: ["mcp-scanner-helper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "mcp-scanner-helper",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/mcp-scanner-helper"
        ),
        .testTarget(
            name: "MCPScannerHelperTests",
            dependencies: ["mcp-scanner-helper"],
            path: "Tests/MCPScannerHelperTests"
        ),
    ]
)
