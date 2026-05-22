// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mcp-scanner-helper",
    // scanline targets minos 15.0 and works; we hung at 13.0. icdd appears to
    // route session-open through a different code path based on the client's
    // LC_BUILD_VERSION min-OS. Bumping to v15 to match scanline.
    platforms: [.macOS(.v15)],
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
            // Swift 6 strict concurrency. ICA's @objc delegate protocols
            // (ICDeviceBrowserDelegate, ICScannerDeviceDelegate) are not
            // main-actor-isolated in Apple's headers, so conforming @MainActor
            // classes use `@preconcurrency` on the conformance.
            // Intentionally no Info.plist embed: matching scanline's structure
            // exactly. With minos=15.0, icdd lets us in, but LaunchServices
            // returns different application metadata depending on whether
            // CFBundle* keys are present. scanline has none; we mirror.
        ),
        .testTarget(
            name: "MCPScannerHelperTests",
            dependencies: ["mcp-scanner-helper"],
            path: "Tests/MCPScannerHelperTests"
        ),
    ]
)
