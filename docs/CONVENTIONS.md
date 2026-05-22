# Conventions

This package is a Node.js + TypeScript MCP server with a bundled Swift helper for macOS scanner integration. Key conventions:

## Language and tooling

### TypeScript (server)
- Node.js 22 LTS with ESM modules.
- TypeScript in strict mode.
- ESLint and Prettier for linting and formatting.
- Vitest for tests; run with `npm test`.
- `tsc --noEmit` for type checks; build with `tsc`.
- Logging via Pino; validation with AJV or Zod.
- Dependencies should be installed normally rather than shimmed. Never use `any` types.

### Swift (`swift-helper/`)
- Swift 6 with strict concurrency enabled (`swift-tools-version: 6.0`).
- macOS 15.0+ deployment target.
- `swift-argument-parser` for the CLI surface.
- `@MainActor` for ICA delegate callbacks (they fire on the main runloop); `MainActor.assumeIsolated` for the synchronous boundaries. `nonisolated(unsafe)` is only acceptable where Apple's APIs aren't yet `Sendable`-annotated.
- XCTest for tests; run with `npm run test:swift`. All tests must be hardware-free (no real scanner needed). Use fixture images + golden JSON files for wire-shape assertions.
- The helper's stdout is part of the wire contract with the Node side — only JSON events on stdout, diagnostics on stderr.

## Project structure
- `src/mcp.ts` bootstraps the MCP server.
- `src/tools/` hold tool implementations.
- `src/services/` handle orchestration (jobs, selection, file I/O).
- `src/services/backends/` holds backend implementations (`sane.ts`, `ica.ts`, `mock.ts`) behind the `Backend` interface in `backend.ts`. Selection lives in `index.ts`.
- `schemas/` contains JSON Schemas for tool contracts.
- `src/tests/` houses unit and integration tests (Vitest).
- `swift-helper/Sources/mcp-scanner-helper/` holds the Swift CLI; `Commands/` for subcommands, `Sources/` root for shared modules (ICA, OCR, JSON events).
- `swift-helper/Tests/MCPScannerHelperTests/` holds XCTest tests.

## Determinism and typed contracts
- Define JSON Schemas for all tool inputs and outputs.
- Validate at boundaries and keep transformation logic pure.
- Avoid side effects outside of `src/services/`.

## Logging and error handling
- Emit structured JSON logs with run and job identifiers.
- Fail fast with descriptive errors and include relevant stderr snippets.

## Security and safety
- Never use `shell: true`; pass argv arrays to child processes (applies to both `execa` from Node and `Process`/`Pipe` from Swift).
- Normalize and sanitize all filesystem paths.
- Handle filename collisions by appending numeric suffixes (`_001`, `_002`, ...).
- The bundled Swift helper is signed + notarized at release time. Never disable signing (`--no-verify`, `noqa`-style suppressions) to bypass a failing CI check — fix the root cause.

## Configuration
- Read configuration from environment variables (supporting `.env`).
- Validate configuration using AJV or Zod before startup.

## Testing
- Unit tests mock child processes and filesystem interactions.
- Contract tests validate sample payloads against the JSON Schemas — and on the Swift side, lock the JSON wire shape exchanged with the Node parent (`JSONEventsTests`, `OptionsJSONTests`).
- Always clean up artifacts created during tests.
- Swift tests must be hardware-free. ICA-dependent code paths (real `list-devices`, real `scan`) are exercised by `scripts/diagnose-ica.sh` manually before each release.

## Development workflow
- Run `make verify` before opening a pull request (runs TS lint, typecheck, tests, build, pack-check, and Swift tests on macOS).
- For changes that cross the Node ↔ Swift boundary, update both sides in the same PR and re-run `npm run test:swift && npm test`.
