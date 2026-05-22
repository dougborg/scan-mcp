# Signing and notarization (macOS helper)

The macOS scanner helper (`mcp-scanner-helper`, bundled as `dist/bin/mcp-scanner-helper` in the npm tarball) is a native Swift CLI that calls into ImageCaptureCore. For end users to run it without Gatekeeper prompts, the published binary should be **codesigned** with a Developer ID Application certificate and **notarized** by Apple.

This is an opt-in step. Local dev builds (`swift build`, plain `npm run build` with no env) produce an unsigned binary that runs fine on the developer's own machine.

## One-time maintainer setup

You need an active **Apple Developer Program** membership ($99/year).

1. **Create a Developer ID Application certificate.**
   - Easiest: Xcode → Settings → Accounts → select your Apple ID → Manage Certificates → `+` → "Developer ID Application". Xcode adds it to your login keychain.
   - Alternative: developer.apple.com → Certificates → `+` → Developer ID Application → upload a CSR from Keychain Access.

2. **Generate an app-specific password** for the notary service.
   - appleid.apple.com → Sign-In and Security → App-Specific Passwords → `+`.
   - Save the generated password somewhere safe.

3. **Store credentials in your keychain** so build scripts don't see the password:
   ```bash
   xcrun notarytool store-credentials "scan-mcp-notary" \
     --apple-id YOUR_APPLE_ID \
     --team-id YOUR_TEAM_ID \
     --password YOUR_APP_SPECIFIC_PASSWORD
   ```

## Building a signed + notarized binary

Set two env vars and run the usual build:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="scan-mcp-notary"
npm run build
```

The `scripts/build-helper.sh` script will:

1. Build a universal binary (arm64 + x86_64) via `swift build -c release --arch arm64 --arch x86_64`.
2. Copy to `dist/bin/mcp-scanner-helper`.
3. Codesign with the hardened runtime: `codesign --options=runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION"`.
4. Zip and submit to the Apple notary service via `xcrun notarytool submit --wait`. Typical turnaround is 1–5 minutes.

Bare CLI binaries can't be `stapler staple`d (only `.app`/`.dmg`/`.pkg`/`.zip` containers can), so Gatekeeper fetches the notarization ticket online at first run on the end user's machine. That's the same model as e.g. signed Homebrew bottles or scripts distributed via curl pipes.

### Notarization cache

The script caches successful notarizations so rebuilds with identical content skip the 30s–2min Apple round-trip. The cache key composes the CDHashes of both arm64 and x86_64 slices (each architecture has its own signature), keeping the key stable regardless of which host built the binary. After a successful `notarytool submit`, a sentinel file is written to `dist/.notary-cache/<arm64hash>-<x86_64hash>.ok`; on the next run, if both slices' CDHashes match the cached key, the submission is skipped. The cache lives under `dist/` (gitignored) and goes away when `dist/` is deleted. Override the location via `NOTARY_CACHE_DIR` (e.g., to persist across CI runs).

## Why both env vars

`DEVELOPER_ID_APPLICATION` alone produces a signed binary that *macOS Gatekeeper still distrusts* (unsigned and signed-but-not-notarized look similar to users — "developer cannot be verified"). Adding `NOTARY_PROFILE` is what makes it trusted on first run.

If you set `DEVELOPER_ID_APPLICATION` but not `NOTARY_PROFILE`, the script signs but skips notarization with a logged warning. This is occasionally useful for internal testing.

## Releasing without signing (interim)

If you publish to npm without signing, users will get Gatekeeper warnings on first invocation. The workaround for them is:

```bash
xattr -d com.apple.quarantine "$(npm root -g)/scan-mcp/dist/bin/mcp-scanner-helper"
```

This is acceptable for early adopters but not for general distribution. Set up the cert + notary profile before announcing.

## CI vs. local

CI (the `verify-macos` job in `.github/workflows/ci.yml`) builds **unsigned** binaries — Developer ID certificates live in the maintainer's local keychain and shouldn't be exported into CI secrets. Release-time signing happens locally when cutting a release.
