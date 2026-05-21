# NOTICE

scan-mcp incorporates third-party software listed below.

## Vendored / adapted source

### scanline

The macOS scanner helper (`swift-helper/`) adapts MIT-licensed code from
**scanline** by Scott J. Kleper:

- <https://github.com/klep/scanline>
- See `swift-helper/LICENSE-scanline` for the full license text.
- See `swift-helper/NOTICE.md` for the file-level breakdown of adaptations.

Specifically: `ScannerBrowser.swift`, `ScannerController.swift`, and the
`IndexSet.integerGreaterThanOrEqualTo` extension are derived from scanline's
`libscanline/` sources. The configuration-parsing, logging, and file-archiving
layers were replaced; ICA framework usage (browser, session management, scan
flow) is structurally based on scanline.

## Runtime dependencies

See `package.json` and `swift-helper/Package.resolved` for the full list of
runtime dependencies. Each retains its own license; key ones:

- `@modelcontextprotocol/sdk` (MIT) — Anthropic
- `swift-argument-parser` (Apache-2.0) — Apple
- `execa` (MIT), `pino` (MIT), `zod` (MIT), `express` (MIT)
