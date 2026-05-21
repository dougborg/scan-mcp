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

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "build:helper: codesigning with $DEVELOPER_ID_APPLICATION"
  codesign --force --options=runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" "$OUT"
else
  # Ad-hoc signing (identity "-") gives the binary a stable signature without a
  # Developer ID cert. macOS uses this signature as the identity for TCC
  # permission grants — without it, a binary that uses NSLocalNetworkUsageDescription
  # will be silently denied because there's nothing for the system to remember
  # the user's "Allow" decision against.
  echo "build:helper: DEVELOPER_ID_APPLICATION not set; ad-hoc signing for TCC compatibility"
  codesign --force --options=runtime --sign - "$OUT"
fi

if [[ -n "${NOTARY_PROFILE:-}" && -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "build:helper: notarizing via $NOTARY_PROFILE (this may take 1-5 minutes)"
  ZIP_PATH="$(mktemp -t mcp-scanner-helper).zip"
  trap 'rm -f "$ZIP_PATH"' EXIT
  /usr/bin/ditto -c -k --keepParent "$OUT" "$ZIP_PATH"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "build:helper: notarization complete"
else
  echo "build:helper: NOTARY_PROFILE not set; skipping notarization"
fi

echo "build:helper: binary ready at $OUT"
ls -la "$OUT"
