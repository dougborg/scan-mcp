#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/notices
cp swift-helper/NOTICE.md dist/notices/NOTICE.md
cp swift-helper/LICENSE-scanline dist/notices/LICENSE-scanline
cp swift-helper/.build/checkouts/swift-argument-parser/LICENSE.txt dist/notices/LICENSE-argument-parser
