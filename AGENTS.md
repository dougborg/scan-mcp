# Agent Guidelines

## Project Layout (multi-language)

- **TypeScript** under `src/` — the MCP server. Backends in `src/services/backends/` (`sane.ts`, `ica.ts`, `mock.ts`); selection via `selectBackend()` in `index.ts`.
- **Swift** under `swift-helper/` — `mcp-scanner-helper`, a native CLI bundled into the npm tarball that wraps `ImageCaptureCore` for macOS. Spawned by `IcaBackend`. Has its own SwiftPM package, sources under `Sources/mcp-scanner-helper/`, tests under `Tests/MCPScannerHelperTests/`.

If you change the JSON wire shape between Node and the Swift helper (events, params, options), update **both sides** and the test fixtures in `swift-helper/Tests/MCPScannerHelperTests/JSONEventsTests.swift` + `OptionsJSONTests.swift`.

## Build, Test, and Development Commands

- Run commands from this directory.
- `make install` installs Node dependencies.
- `make lint`, `make typecheck`, `make test`, `make build`, `make verify` mirror `package.json` scripts.
- `npm test` runs the Vitest suite (TS, ~58 tests, uses `SCAN_MOCK=true`).
- `npm run test:swift` runs `swift test --package-path swift-helper` (~21 hardware-free Swift tests). macOS only.
- `npm run build` compiles TypeScript and, on macOS, builds the Swift helper via `scripts/build-helper.sh` into `dist/bin/mcp-scanner-helper`. On Linux the Swift step is skipped automatically.
- `bash scripts/diagnose-ica.sh` (macOS) is the end-to-end smoke against a real scanner — handy when iterating on the helper.

## Platform Notes

- **macOS work**: the helper requires `swift-tools-version: 6.0` (Swift 6 strict concurrency) and `macOS 15.0+` deployment target. ICA delegates fire on the main runloop; `@MainActor` annotations and `MainActor.assumeIsolated` are load-bearing — do not strip them. See `swift-helper/README.md` for the CLI surface.
- **Signing/notarization**: release-time only, env-gated (`DEVELOPER_ID_APPLICATION` + `NOTARY_PROFILE`). CI ships unsigned builds; signing happens locally via `scripts/build-helper.sh`. See [`docs/SIGNING.md`](./docs/SIGNING.md).
- **Linux work**: the SANE path is unaffected by any change inside `swift-helper/`. CI's Ubuntu job will not catch Swift breakage; the macos-14 job does.

## Code & Project Conventions
- See [CONVENTIONS.md](./docs/CONVENTIONS.md) for coding style, project structure, security, and testing guidelines.

## Commit & Pull Request Guidelines
- Use conventional commit prefixes when practical (`feat:`, `fix:`, `docs:`, etc.).
- Keep commits focused and run `make verify` before sending a PR.
- PRs should include a concise summary and relevant command output.

## Releases (release-please)
- This repo uses release-please to automate versioning and changelog generation.
- Do not manually bump versions in `package.json` or other manifests.
- Use conventional commits; release-please derives the next version from commit history.
- If you need to force a specific version for a PR, include a line in the merge (squash) commit message body:
  - `Release-As: x.y.z`
- CI will open or update a release PR; merging it publishes the release per the configured workflow.

## Network and Approvals Policy
- Network access is allowed for installing packages, fetching docs, or calling external APIs.
- If the sandbox blocks a command, re-run it with elevated permissions and a brief justification.
- Do not commit secrets; document required environment variables instead.
