# mcp-scanner-helper

A native macOS CLI that wraps Apple's [ImageCaptureCore](https://developer.apple.com/documentation/imagecapturecore) framework with a JSON-over-stdio interface. It's the macOS-side backend for [scan-mcp](https://github.com/jacksenechal/scan-mcp).

End users don't run this directly — scan-mcp spawns it from its Node process. The CLI is documented here for development and debugging.

## Subcommands

```
mcp-scanner-helper list-devices [--browse-seconds N]
mcp-scanner-helper device-options --device-id <persistentID> [--browse-seconds N]
mcp-scanner-helper capabilities
mcp-scanner-helper scan --params <json> --out-dir <dir> [--browse-seconds N]
```

- `list-devices` browses for USB scanners, Bonjour `_uscan._tcp` (AirScan/eSCL) network scanners, and macOS-shared scanners for `browse-seconds`, then emits one JSON object on stdout: `{"devices":[{"id":"...","vendor":"...","model":"...","name":"..."}]}`. The `id` field is `ICScannerDevice.persistentIDString` — pass it to other subcommands.

- `device-options` opens a session with the specified scanner and reports its functional units, supported resolutions, color modes, and ADF/duplex capabilities: `{"sources":["Flatbed","ADF","ADF Duplex"],"color_modes":["Color","Gray","Lineart"],"resolutions":[200,300,600],"adf":true,"duplex":true}`.

- `capabilities` reports the helper's own runtime metadata: macOS version, AI feature availability, supported output formats. Synchronous, no scanner needed.

- `scan` is the workhorse. It accepts a JSON `--params` blob matching scan-mcp's `StartScanInput` shape and writes pages into `--out-dir`. Emits one JSON event per line on stdout:

  ```
  {"type":"stage","stage":"discovering","timestamp":"..."}
  {"type":"stage","stage":"opening_session","timestamp":"..."}
  {"type":"stage","stage":"scanning","timestamp":"..."}
  {"type":"page_scanned","index":1,"path":"...","timestamp":"..."}
  {"type":"page_scanned","index":2,"path":"...","timestamp":"..."}
  {"type":"stage","stage":"finalizing","timestamp":"..."}    # when output_format is pdf-searchable
  {"type":"complete","pages":["..."],"document":"...","timestamp":"..."}
  ```

  On error: `{"type":"error","message":"...","timestamp":"..."}`. Diagnostics go to stderr (not parsed by scan-mcp).

  When `params.output_format` is `pdf` or `pdf-searchable`, the helper assembles the per-page TIFFs into a multipage PDF at `<out-dir>/doc_0001.pdf` after scanning completes. For `pdf-searchable`, each page also gets a Vision-OCR'd invisible text layer embedded via `CGPDFContext` — the same approach Image Capture's OCR checkbox uses.

## Building

```bash
swift build -c release --arch arm64 --arch x86_64
```

For signed + notarized release builds, see [`docs/SIGNING.md`](../docs/SIGNING.md) in the parent repository.

## Why a separate Swift CLI

ImageCaptureCore is delegate-based, requires a CFRunLoop, and isn't directly callable from Node. A small native binary is the cleanest bridge: scan-mcp's Node side spawns it, parses its JSON line stream, and exits. The Swift code stays self-contained without dragging FFI / N-API complexity into the MCP server.

## Attribution

Adapted from MIT-licensed [scanline](https://github.com/klep/scanline) by Scott J. Kleper. See `LICENSE-scanline` and `NOTICE.md` for the full attribution.
