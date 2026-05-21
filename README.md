<p align="center">
  <img src="docs/assets/icon.png" alt="scan-mcp logo" width="96">
</p>

<h1 align="center">scan-mcp</h1>


[![CI](https://github.com/jacksenechal/scan-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/jacksenechal/scan-mcp/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/scan-mcp.svg)](https://www.npmjs.com/package/scan-mcp)
![node-current](https://img.shields.io/node/v/scan-mcp)
[![npm downloads](https://img.shields.io/npm/dm/scan-mcp.svg)](https://www.npmjs.com/package/scan-mcp)


Minimal MCP server for scanner capture (ADF/duplex/page-size), batching, and multipage assembly.

## Features

- Small, typed MCP server exposing tools for device discovery and scan jobs
- JSON Schema–validated inputs with deterministic, typed outputs
- Smart device selection (prefers ADF/duplex, avoids camera backends), robust defaults
- Local-first transports: stdio by default to keep everything on-device, optional HTTP for your own network deployments

Note: This package targets Node 22 and Linux SANE backends (`scanimage`).

## Quick Start (local stdio, default)

Add a server entry to your MCP client configuration:

```
{
  "mcpServers": {
    "scan": {
      "command": "npx",
      "args": [
        "-y",
        "scan-mcp"
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

- Run with npx: `npx scan-mcp` (recommended)
  - The CLI runs a quick preflight check for Node 22+ and required scanner/image tools and prints installation hints if anything is missing.
  - See recommended server config above
- Use `npx scan-mcp --http` to launch the streamable HTTP transport when running on another machine.
- CLI help: `scan-mcp --help`
- From source (for development):
  - `npm install`
  - `npm run build`
- For Cline setup, and other automated agentic installation, see [llms-install.md](llms-install.md)

## System Requirements

scan-mcp supports both Linux (via SANE) and macOS (via Apple's ImageCaptureCore framework).

### Linux

- SANE utilities: `scanimage` (and optionally `scanadf`)
- TIFF tools: `tiffcp` (preferred) or ImageMagick `convert`

### macOS

- macOS 13 (Ventura) or newer.
- No external tools required — the npm package ships a bundled native helper binary (`mcp-scanner-helper`) that wraps ImageCaptureCore.
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
    - `output_format` (string, default `tiff`)
    - `tmp_dir` (string)

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

## Roadmap

Tracking ideas and future improvements are documented in `docs/ROADMAP.md`.
