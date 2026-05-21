# scan-mcp Blueprint

This document outlines the architecture and goals of the scan-mcp server.

## Goals and scope
- Enumerate scanners and capture pages with control over ADF, duplex, and page size.
- Support batching, document breaks, and multi-page TIFF assembly.
- Produce deterministic outputs and a manifest for downstream processing.

## System overview
- Artifacts are written under `inbox/<job_id>/`:
  - `page_*.tiff` and `doc_*.tiff` files
  - `manifest.json` and `events.jsonl`
- Clients may pass resulting TIFFs to other services (e.g., OCR) for further processing.
- Tool contracts are defined with JSON Schemas located in `schemas/`.

## Tools
- `list_devices()` → returns devices and capabilities
- `get_device_options(device_id)` → parsed output of `scanimage -A`
- `start_scan_job(config)` → `{ job_id, run_dir, state }`
- `get_job_status(job_id)` → dynamic job state and artifacts
- `cancel_job(job_id)` → request cancellation

## Resources
- `scan://jobs/<job_id>/events` — append-only JSONL event log
- `scan://jobs/<job_id>/manifest` — manifest JSON describing documents and pages

## Implementation notes
- On Linux, prefer `scanadf` for ADF capture; fallback to `scanimage --batch`.
- On macOS, drive the scanner via Apple's ImageCaptureCore framework through the bundled `mcp-scanner-helper` Swift binary (see Backends below).
- Assemble multipage TIFFs with `tiffcp` when available, otherwise ImageMagick `convert`. The ICA backend can also produce searchable PDFs directly via Vision OCR + CGPDFContext.
- Document breaks: blank-page threshold, page count, or timer.
- Manifest structure defined in `schemas/manifest.schema.json`.
- Idempotency: document hash = hash of concatenated page hashes to avoid duplicates.

## Backends

`src/services/jobs.ts` and tool handlers in `src/server/register.ts` never talk to the scanner directly — they go through `ctx.backend`, which implements the `Backend` interface in `src/services/backends/backend.ts`:

```ts
interface Backend {
  name: "sane" | "ica" | "mock";
  listDevices(ctx): Promise<Device[]>;
  getDeviceOptions(deviceId, ctx): Promise<DeviceOptions>;
  runScan(args): Promise<{ ran: boolean }>;  // writes page_NNNN.tiff into args.runDir
  probeResolution?(deviceId, dpi, ctx): Promise<boolean>;  // optional, SANE only
}
```

Implementations in `src/services/backends/`:

- **`sane.ts`** (`SaneBackend`) — shells out to `scanimage` from the SANE project. Default on Linux. Parses backend prefixes (`epjitsu:`, `genesys:`, etc.) for exclusion/preference scoring.
- **`ica.ts`** (`IcaBackend`) — spawns the bundled `mcp-scanner-helper` Swift binary at `dist/bin/mcp-scanner-helper`. Default on macOS. Streams per-line JSON events for live progress.
- **`mock.ts`** (`MockBackend`) — synthesizes device listings and writes placeholder TIFFs. Selected when `SCAN_MOCK=true`. Used by the test suite.
- **`index.ts`** — `selectBackend(config)` picks the right impl based on `SCAN_MOCK` first, then explicit `SCAN_BACKEND` env, then platform autodetect.

Backend selection happens once per process in `src/mcp.ts` / `src/http-server.ts` and the result is stored on `AppContext.backend`. Tests inject `Backend` impls directly without needing a config override.

The Swift helper used by the ICA backend is built from source under `swift-helper/`. See `swift-helper/README.md` for the helper's CLI and `docs/SIGNING.md` for release-time signing/notarization via Developer ID + notarytool.
