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
            path: "Sources/mcp-scanner-helper",
            linkerSettings: [
                // Embed Info.plist into the binary's __TEXT,__info_plist section.
                // macOS reads this for Bonjour service declarations and the
                // NSLocalNetworkUsageDescription required by Sonoma+ TCC.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "MCPScannerHelperTests",
            dependencies: ["mcp-scanner-helper"],
            path: "Tests/MCPScannerHelperTests"
        ),
    ]
)
