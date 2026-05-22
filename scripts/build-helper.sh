#!/usr/bin/env bash
#
# Build the macOS/ICA scanner helper as a universal binary and copy it into
# dist/bin/. Optionally signs and notarizes if the appropriate env vars are set.
#
# Env vars:
#   DEVELOPER_ID_APPLICATION  Full identity, e.g. "Developer ID Application: Doug Borg (AN7VQUD6ZL)"
#                             When set, codesigns the binary with hardened runtime.
#   NOTARY_PROFILE            Notarytool keychain profile name (created via
#                             `xcrun notarytool store-credentials <name>`).
#                             When set together with DEVELOPER_ID_APPLICATION,
#                             submits the binary to Apple's notary service.
#   NOTARY_CACHE_DIR          Directory holding `<cdhash>.ok` sentinel files for
#                             binaries already accepted by the notary service.
#                             Defaults to `dist/.notary-cache`. When a sentinel
#                             matching the freshly-signed binary's CDHash exists,
#                             `notarytool submit` is skipped.
#
# This is a no-op on non-macOS platforms (Linux installs use only the SANE backend).

set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "build:helper: not on macOS, skipping Swift helper build"
  exit 0
fi

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

echo "build:helper: building universal release binary"
cd "$ROOT/swift-helper"
swift build -c release --arch arm64 --arch x86_64
cd "$ROOT"

mkdir -p "$ROOT/dist/bin"
HELPER_BIN="$ROOT/swift-helper/.build/apple/Products/Release/mcp-scanner-helper"
if [[ ! -f "$HELPER_BIN" ]]; then
  echo "build:helper: ERROR — expected binary not found at $HELPER_BIN" >&2
  exit 1
fi
cp "$HELPER_BIN" "$ROOT/dist/bin/mcp-scanner-helper"
chmod +x "$ROOT/dist/bin/mcp-scanner-helper"

OUT="$ROOT/dist/bin/mcp-scanner-helper"

ENTITLEMENTS="$ROOT/swift-helper/mcp-scanner-helper.entitlements"
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "build:helper: WARNING — entitlements file missing at $ENTITLEMENTS" >&2
fi

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "build:helper: codesigning with $DEVELOPER_ID_APPLICATION"
  codesign --force --options=runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APPLICATION" "$OUT"
else
  # Ad-hoc signing (identity "-") gives the binary a stable signature without a
  # Developer ID cert. ICA's per-device modules (e.g., AirScanScanner.app)
  # silently drop session-open requests unless we declare
  # com.apple.application-identifier — so we sign with the same entitlements
  # in dev mode too, even though the application-identifier won't be honored
  # by Apple's servers without a proper Developer ID + provisioning profile.
  echo "build:helper: DEVELOPER_ID_APPLICATION not set; ad-hoc signing (ICA will likely fail)"
  codesign --force --options=runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign - "$OUT"
fi

if [[ -n "${NOTARY_PROFILE:-}" && -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  # CDHash uniquely identifies a slice's code+signature. A universal binary
  # has one CDHash per architecture, and `codesign -d` without --arch returns
  # only the host slice's hash — composing both makes the cache key cover the
  # entire artifact and stay stable across arm64 vs x86_64 build hosts.
  CDHASH_ARM64=$(codesign -d --verbose=4 --arch arm64 "$OUT" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')
  CDHASH_X86_64=$(codesign -d --verbose=4 --arch x86_64 "$OUT" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')
  if [[ -z "$CDHASH_ARM64" || -z "$CDHASH_X86_64" ]]; then
    echo "build:helper: ERROR — could not extract per-slice CDHashes from $OUT (arm64=$CDHASH_ARM64 x86_64=$CDHASH_X86_64)" >&2
    exit 1
  fi
  CACHE_KEY="${CDHASH_ARM64}-${CDHASH_X86_64}"
  NOTARY_CACHE_DIR="${NOTARY_CACHE_DIR:-$ROOT/dist/.notary-cache}"
  CACHE_SENTINEL="$NOTARY_CACHE_DIR/$CACHE_KEY.ok"

  if [[ -f "$CACHE_SENTINEL" ]]; then
    echo "build:helper: $CACHE_KEY already notarized (cache hit); skipping submission"
  else
    echo "build:helper: notarizing via $NOTARY_PROFILE (this may take 1-5 minutes)"
    ZIP_PATH="/tmp/mcp-scanner-helper-notarize-$$.zip"
    trap 'rm -f "$ZIP_PATH"' EXIT
    /usr/bin/ditto -c -k --keepParent "$OUT" "$ZIP_PATH"
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    mkdir -p "$NOTARY_CACHE_DIR"
    : > "$CACHE_SENTINEL"
    echo "build:helper: notarization complete; cached at $CACHE_SENTINEL"
  fi
else
  echo "build:helper: NOTARY_PROFILE not set; skipping notarization"
fi

echo "build:helper: binary ready at $OUT"
ls -la "$OUT"
