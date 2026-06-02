<p align="center">
  <img src="docs/assets/icon.png" alt="scan-mcp logo" width="96">
</p>

<h1 align="center">scan-mcp</h1>


[![CI](https://github.com/dougborg/scan-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/dougborg/scan-mcp/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/@dougborg/scan-mcp.svg)](https://www.npmjs.com/package/@dougborg/scan-mcp)
![node-current](https://img.shields.io/node/v/@dougborg/scan-mcp)
[![npm downloads](https://img.shields.io/npm/dm/@dougborg/scan-mcp.svg)](https://www.npmjs.com/package/@dougborg/scan-mcp)


Minimal MCP server for scanner capture (ADF/duplex/page-size), batching, and multipage assembly.

> **Maintained fork.** This is the maintained fork of [`jacksenechal/scan-mcp`](https://github.com/jacksenechal/scan-mcp),
> adding a macOS / ImageCaptureCore (ICA) backend, simplex-to-duplex page assembly, and Vision-OCR'd
> searchable-PDF output. Published on npm as [`@dougborg/scan-mcp`](https://www.npmjs.com/package/@dougborg/scan-mcp).
> The CLI command and MCP server identifier remain `scan-mcp`.

## Differences from upstream

- **macOS / ICA backend** — native capture through Apple's ImageCaptureCore via a bundled, signed-and-notarized helper binary. No SANE required on macOS. (Upstream is SANE/Linux only.)
- **Simplex-to-duplex assembly** — `assemble_duplex` interleaves two one-sided scan passes (fronts, then a flipped stack of backs) into a single duplex document, for feeders without a true `ADF Duplex` source.
- **Searchable PDF output** — `output_format: "pdf-searchable"` embeds a Vision-OCR'd invisible text layer behind each page (macOS/ICA).
- **Maintained** — Dependabot enabled, regular releases. See [docs/PUBLISHING.md](docs/PUBLISHING.md).

## Features

- Small, typed MCP server exposing tools for device discovery and scan jobs
- JSON Schema–validated inputs with deterministic, typed outputs
- Smart device selection (prefers ADF/duplex, avoids camera backends), robust defaults
- Local-first transports: stdio by default to keep everything on-device, optional HTTP for your own network deployments

Targets Node 22+ on Linux (via SANE / `scanimage`) and macOS (via Apple's ImageCaptureCore through a bundled native helper). See [System Requirements](#system-requirements).

## Quick Start (local stdio, default)

Add a server entry to your MCP client configuration:

```json
{
  "mcpServers": {
    "scan": {
      "command": "npx",
      "args": [
        "-y",
        "@dougborg/scan-mcp"
      ],
      "env": {
        "INBOX_DIR": "~/Documents/scanned_documents/inbox"
      }
    }
  }
}
```

- This invocation runs over stdio for a privacy-first, single-machine setup.
- Call `start_scan_job` without a `device_id` to auto-select a scanner and begin scanning.
- Artifacts are written under `INBOX_DIR` per job: `job-*/page_*.tiff`, `doc_*.tiff`, `manifest.json`, `events.jsonl`.

## Examples

**Scan a duplex stack in one pass** (scanner has an `ADF Duplex` source):

```jsonc
start_scan_job({ "source": "ADF Duplex" })
```

**Two-pass duplex** (feeder has only `ADF`): scan fronts, flip the stack, scan backs, then interleave.
Set `output_format: "pdf-searchable"` on both passes to get an OCR'd PDF in the merged output:

```jsonc
start_scan_job({ "source": "ADF", "output_format": "pdf-searchable" })   // -> front_job_id
// flip the stack in the feeder, then:
start_scan_job({ "source": "ADF", "output_format": "pdf-searchable" })   // -> back_job_id
assemble_duplex({ "front_job_id": "...", "back_job_id": "...", "dry_run": true })  // preview page order
assemble_duplex({ "front_job_id": "...", "back_job_id": "..." })                  // write merged job
```

**Searchable PDF from a flatbed photo-quality scan:**

```jsonc
start_scan_job({ "source": "Flatbed", "color_mode": "Color", "resolution_dpi": 600, "output_format": "pdf-searchable" })
```

## Streamable HTTP transport

Prefer to attach the scanner to another machine on your network? `scan-mcp` also supports the
streamable HTTP transport:

```bash
scan-mcp --http
```

- Default port is `3001`; set `MCP_HTTP_PORT` to override (for example `MCP_HTTP_PORT=3333 scan-mcp --http`).
- HTTP responses use server-sent events (SSE) for streaming tool output; clients such as Claude Desktop and Windsurf support
  this transport.
- There is currently no authentication; this is intended for internal LAN networking

## Install

- Run with npx: `npx -y @dougborg/scan-mcp` (recommended)
  - The CLI runs a quick preflight check for Node 22+ and required scanner/image tools and prints installation hints if anything is missing.
  - See recommended server config above
- Use `npx -y @dougborg/scan-mcp --http` to launch the streamable HTTP transport when running on another machine.
- CLI help: `scan-mcp --help`
- From source (for development):
  - `npm install`
  - `npm run build`
- For Cline setup, and other automated agentic installation, see [llms-install.md](llms-install.md)

## System Requirements

scan-mcp supports both Linux (via SANE) and macOS (via Apple's ImageCaptureCore framework).

| Platform | Backend | Capture | Duplex assembly | Searchable PDF |
| --- | --- | --- | --- | --- |
| macOS | ICA (bundled helper) | ✅ | ✅ | ✅ (Vision OCR) |
| Linux | SANE (`scanimage`) | ✅ | ✅ | ⏳ TIFF/PDF; OCR pending ([#10](https://github.com/dougborg/scan-mcp/issues/10)) |
| Windows | — | ❌ | ❌ | ❌ |

### Linux

- SANE utilities: `scanimage` (and optionally `scanadf`)
- TIFF tools: `tiffcp` (preferred) or ImageMagick `convert`

### macOS

- macOS 15 (Sequoia) or newer. The bundled helper requires this minimum because `icdd` rejects ImageCaptureCore session-open from clients built against older SDKs.
- No external tools required — the npm package ships a bundled native helper binary (`mcp-scanner-helper`) that wraps ImageCaptureCore. The binary is signed with a Developer ID certificate and notarized by Apple, so Gatekeeper allows it without prompts on first launch.
- Network scanners that speak AirScan / eSCL are auto-discovered via Bonjour (same as the built-in `Image Capture.app`); USB scanners and macOS-shared scanners are also supported.
- First-time use may prompt for ICA / network permission in System Settings → Privacy & Security.
- Apple Intelligence-powered features (autoname, summarize) require macOS 26+ and are runtime-detected — query the `get_capabilities` tool to see what's available.

### Output formats

- `tiff` (default) — one TIFF per page plus a multipage doc TIFF assembled at the end.
- `pdf` — same as TIFF, then combined into a single PDF.
- `pdf-searchable` (macOS/ICA only) — same as PDF, plus a Vision-OCR'd invisible text layer embedded behind each page. Matches what Image Capture's "OCR" checkbox or Adobe Acrobat's "Recognize Text" produce: visually identical to the scan, but text is selectable in Preview, searchable in Spotlight, and extractable with `pdftotext`.

## Environment Variables

- `SCAN_MOCK` (default: `false`): use a mock backend that synthesizes fake devices and TIFFs. Useful for testing.
- `SCAN_BACKEND` (optional, `sane` | `ica`): force a specific backend. Default is platform autodetect (darwin → ica, others → sane).
- `INBOX_DIR` (default: `scanned_documents/inbox`): base directory for job runs and artifacts.
- `MCP_SCANNER_HELPER_BIN` (macOS only): override the path to the bundled `mcp-scanner-helper` binary. Useful for local development.
- `SCANIMAGE_BIN` / `SCANADF_BIN` (defaults: `scanimage` / `scanadf`): override SANE binary paths (Linux/SANE only).
- `TIFFCP_BIN` / `IM_CONVERT_BIN` (defaults: `tiffcp` / `convert`): multipage assembly tools (Linux/SANE only).
- `SCAN_EXCLUDE_BACKENDS` (CSV, default: `v4l`): backend prefixes to exclude (SANE only).
- `SCAN_PREFER_BACKENDS` (CSV): preferred backend prefixes (SANE only).
- `PERSIST_LAST_USED_DEVICE` (default: `true`): persist and lightly prefer last used device.
- `MCP_HTTP_PORT` (default: `3001`): TCP port for the HTTP transport.

## API

### Tools

- **list_devices**
  - Discover connected scanners with backend details.
  - Inputs: none.

- **get_device_options**
  - Get SANE options for a specific device.
  - Inputs:
    - `device_id` (string): Target device identifier.

- **start_scan_job**
  - Begin a scanning job; omitting `device_id` triggers auto-selection and default options.
  - Inputs (all optional unless noted):
    - `device_id` (string)
    - `resolution_dpi` (integer, 50–1200)
    - `color_mode` (`Color` | `Gray` | `Lineart`)
    - `source` (`Flatbed` | `ADF` | `ADF Duplex`)
    - `duplex` (boolean)
    - `page_size` (`Letter` | `A4` | `Legal` | `Custom`)
    - `custom_size_mm` { `width`, `height` }
    - `doc_break_policy` { `type`, `blank_threshold`, `page_count`, `timer_ms`, `barcode_values` }
    - `output_format` (string, default `tiff`; `tiff` | `pdf` | `pdf-searchable`)
    - `tmp_dir` (string)

- **assemble_duplex**
  - Interleave two completed simplex scan jobs (fronts + a flipped stack of backs) into a single duplex document.
  - Inputs:
    - `front_job_id` (string)
    - `back_job_id` (string)
    - `back_order` (`reversed` | `natural`, default `reversed` — matches a normal ADF flip)
    - `dry_run` (boolean): return the planned page order without writing.

- **get_job_status**
  - Inspect job state and artifact counts.
  - Inputs:
    - `job_id` (string)

- **cancel_job**
  - Request job cancellation; best effort during scan loops.
  - Inputs:
    - `job_id` (string)

- **list_jobs**
  - List recent jobs from the inbox directory.
  - Inputs (optional):
    - `limit` (integer, max 100)
    - `state` (`running` | `completed` | `cancelled` | `error` | `unknown`)

- **get_manifest**
  - Fetch a job's `manifest.json`.
  - Inputs:
    - `job_id` (string)

- **get_events**
  - Retrieve a job's `events.jsonl` log.
  - Inputs:
    - `job_id` (string)

See JSON Schemas in `schemas/` for input shapes. Tests assert against these contracts.

## How Selection and Defaults Work

Defaults aim for 300dpi, reasonable color mode, and ADF/duplex when available. Full details on scoring and fallbacks live in docs:

- Selection and defaults: `docs/SELECTION.md`

## Project Layout

- `src/mcp.ts` — MCP server entry and tool registration
- `src/services/*` — hardware interface and job orchestration
- `schemas/` — JSON Schemas used for validation and tests
- `docs/` — architecture, conventions, and deep dives

## Development

- `npm run dev` (stdio MCP server), `npm run dev:http` (HTTP transport)
- `make verify` runs lint, typecheck, and tests
- Conventions: `docs/CONVENTIONS.md` and architecture in `docs/BLUEPRINT.md`

## Releasing

Releases are automated with release-please + npm Trusted Publishing. See [docs/PUBLISHING.md](docs/PUBLISHING.md).

## Roadmap

Tracking ideas and future improvements are documented in `docs/ROADMAP.md`.
