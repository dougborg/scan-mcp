#!/usr/bin/env bash
#
# Build scan-mcp as a Node Single Executable Application (SEA): one self-contained
# binary plus the Swift scanner helper shipped alongside it. The compiled binary
# has a stable path and signature, so macOS folder/scanner permission grants stick
# across node upgrades instead of re-prompting (unlike launching via a volta shim).
#
# Output: dist-sea/scan-mcp  (+ dist-sea/mcp-scanner-helper)
#
# Requires: node 22+, esbuild (devDep), postject (fetched via npx if absent).

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

OUT_DIR="dist-sea"
BUNDLE="$OUT_DIR/scan-mcp.cjs"
BLOB="$OUT_DIR/sea-prep.blob"
BIN="$OUT_DIR/scan-mcp"

# Resolve the real node binary (past any volta/symlink shim) and derive its SEA
# fuse sentinel from the binary itself — the fuse value changes between node
# releases, so hardcoding it breaks on upgrade.
NODE_REAL="$(node -e 'process.stdout.write(process.execPath)')"
# Capture fully, then match with a bash regex — piping `strings` into `grep -m1`
# makes grep close the pipe early, and pipefail turns the resulting SIGPIPE into
# a fatal error.
NODE_STRINGS="$(strings -a "$NODE_REAL")"
FUSE=""
if [[ "$NODE_STRINGS" =~ (NODE_SEA_FUSE_[0-9a-f]+) ]]; then
  FUSE="${BASH_REMATCH[1]}"
fi
if [[ -z "$FUSE" ]]; then
  echo "build:sea: ERROR — could not find NODE_SEA_FUSE sentinel in $NODE_REAL" >&2
  exit 1
fi
echo "build:sea: node=$NODE_REAL fuse=$FUSE"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "==> [1/7] Building Swift scanner helper"
npm run --silent build:helper

echo "==> [2/7] Bundling TypeScript -> single CommonJS file (esbuild)"
node_modules/.bin/esbuild src/sea-entry.ts \
  --bundle \
  --platform=node \
  --format=cjs \
  --target=node22 \
  --outfile="$BUNDLE" \
  --external:node:sea \
  --define:process.env.NODE_ENV='"production"' \
  --log-level=warning

echo "==> [3/7] Generating SEA blob"
node --experimental-sea-config sea-config.json

echo "==> [4/7] Copying node binary"
cp "$NODE_REAL" "$BIN"
chmod u+w "$BIN"

if [[ "$(uname)" == "Darwin" ]]; then
  echo "==> [5/7] Removing existing signature (macOS)"
  codesign --remove-signature "$BIN" || true
else
  echo "==> [5/7] (skip signature removal — not macOS)"
fi

echo "==> [6/7] Injecting SEA blob (postject)"
POSTJECT_ARGS=("$BIN" NODE_SEA_BLOB "$BLOB" --sentinel-fuse "$FUSE")
if [[ "$(uname)" == "Darwin" ]]; then
  POSTJECT_ARGS+=(--macho-segment-name NODE_SEA)
fi
if [[ -x node_modules/.bin/postject ]]; then
  node_modules/.bin/postject "${POSTJECT_ARGS[@]}"
else
  npx --yes postject "${POSTJECT_ARGS[@]}"
fi

if [[ "$(uname)" == "Darwin" ]]; then
  echo "==> [7/7] Re-signing (ad-hoc) + shipping Swift helper"
  codesign --sign - "$BIN"
else
  echo "==> [7/7] Shipping Swift helper"
fi

HELPER="$ROOT/dist/bin/mcp-scanner-helper"
[[ -f "$HELPER" ]] || HELPER="$ROOT/swift-helper/.build/release/mcp-scanner-helper"
cp "$HELPER" "$OUT_DIR/mcp-scanner-helper"
chmod +x "$OUT_DIR/mcp-scanner-helper"

chmod +x "$BIN"
echo ""
echo "==> Done."
echo "    Binary: $ROOT/$BIN"
echo "    Helper: $ROOT/$OUT_DIR/mcp-scanner-helper"
ls -lh "$BIN" "$OUT_DIR/mcp-scanner-helper"
