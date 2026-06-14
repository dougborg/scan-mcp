# NOTICE

`mcp-scanner-helper` is the macOS/ICA backend helper for [scan-mcp](https://github.com/dougborg/scan-mcp).

## Third-party code

This helper adapts MIT-licensed code from **scanline** by Scott J. Kleper:
- <https://github.com/klep/scanline>
- See `LICENSE-scanline` for the original license text.

Files adapted from scanline:
- `Sources/mcp-scanner-helper/ScannerBrowser.swift` — derived from `libscanline/ScannerBrowser.swift`
- `Sources/mcp-scanner-helper/ScannerController.swift` — derived from `libscanline/ScannerController.swift`
- `Sources/mcp-scanner-helper/Extensions.swift` — `IndexSet.integerGreaterThanOrEqualTo`

Adaptations include: removing the `ScanConfiguration` argv parser in favor of JSON params,
replacing the textual `Logger` with structured JSON event output, removing the file-archiving
output processor in favor of writing into a caller-provided output directory, and adding a
Vision + CoreGraphics searchable-PDF pipeline.

## Vendored dependencies

- [`swift-argument-parser`](https://github.com/apple/swift-argument-parser) — Apache License 2.0
