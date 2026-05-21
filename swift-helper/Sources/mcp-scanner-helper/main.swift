import ArgumentParser

struct MCPScannerHelper: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp-scanner-helper",
        abstract: "ICA-backed scanner helper for scan-mcp on macOS",
        version: "0.1.0",
        subcommands: [
            ListDevices.self,
            DeviceOptions.self,
            Capabilities.self,
            Scan.self,
        ]
    )
}

MCPScannerHelper.main()
