# Publishing

Releases are automated. In the normal case you do **one thing**: merge the release-please PR.

## How it works

1. Commits land on `main` using [Conventional Commits](https://www.conventionalcommits.org/)
   (`feat:`, `fix:`, etc. — see [CONVENTIONS.md](CONVENTIONS.md)).
2. [`release-please`](../.github/workflows/release-please.yml) watches `main` and keeps an open
   **release PR** with the computed next version, an updated `CHANGELOG.md`, and bumped versions in
   `package.json` and `server.json` (via the `extra-files` entries in
   [`release-please-config.json`](../release-please-config.json)).
3. **Merge that PR.** release-please tags `vX.Y.Z` and creates a GitHub Release.
4. The tag/release triggers [`release.yml`](../.github/workflows/release.yml), which:
   - rebuilds and re-verifies from the tagged commit (lint, typecheck, build, pack check, tests),
   - confirms `package.json` and `server.json` versions match,
   - publishes `@dougborg/scan-mcp` to npm with **Trusted Publishing + provenance** (no token),
   - publishes the server manifest to the **MCP Registry** via GitHub OIDC.

That's it — no manual `npm publish`, no token handling.

## One-time prerequisites

These must be set up once before the first publish (`0.3.0`) succeeds:

- **npm Trusted Publisher.** On npmjs.com, under the `@dougborg` scope/org → *Trusted Publishers*,
  add this repository's release workflow:
  - Repository: `dougborg/scan-mcp`
  - Workflow filename: `release.yml`
  - Environment: (leave blank unless the workflow sets one)
  Trusted Publishing lets the workflow publish without an `NPM_TOKEN`, and `NPM_CONFIG_PROVENANCE`
  attaches a verifiable provenance statement. (Ensure the `@dougborg` npm scope exists first.)
- **MCP Registry ownership.** The registry verifies ownership of `io.github.dougborg/scan-mcp` via
  GitHub OIDC from this repo, so no extra credential is needed — confirm it resolves on the first
  publish run.
- **macOS helper signing** (separate concern) is documented in [SIGNING.md](SIGNING.md). CI builds an
  unsigned helper; release-time signing is handled per that doc.

## Cutting a release manually

The workflow also accepts `workflow_dispatch`, and `release-please.yml` can be re-run from the
Actions tab if the release PR needs regenerating. Avoid pushing tags by hand — let release-please own
versioning so `CHANGELOG.md` and the manifest versions stay in sync.

## Versioning

[Semantic versioning](https://semver.org/), pre-1.0: `feat:` bumps the minor, `fix:` bumps the patch,
and breaking changes (`!` / `BREAKING CHANGE:`) also bump the minor while we are on `0.x`
(`bump-minor-pre-major` in the release-please config). `0.3.0` is the first release of this fork.
