#!/usr/bin/env bash
#
# ICA/icdd diagnostic harness.
#
# Captures parallel system traces around a scan attempt so we can compare
# what icdd does for a known-working binary (scanline) vs our helper.
#
# Per-run captures (saved under /tmp/ica-diag/<name>/):
#   log.log          — unified log stream filtered to imagecapture/security/tcc
#   fs_usage.log     — every file/socket open by icdd and its children
#   icdd-sample.txt  — `sample icdd` snapshot (call graph during the run)
#   codesign.txt     — full signature dump of the binary under test
#   entitlements.txt — entitlements XML
#   launchctl.txt    — `launchctl print pid/<our-pid>` while running
#   loaded.txt       — vmmap and otool -L (dyld load info)
#   stdout.log / stderr.log — binary output
#
# Usage:
#   ./scripts/diagnose-ica.sh ours       # test our binary
#   ./scripts/diagnose-ica.sh scanline   # test reference scanline binary
#   ./scripts/diagnose-ica.sh diff       # diff scanline vs ours captures
#   ./scripts/diagnose-ica.sh clean      # rm -rf /tmp/ica-diag
#
# Requires: sudo (cached at start). Some diagnostics need root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_BASE="/tmp/ica-diag"
SCANLINE_BIN="/tmp/scanline-extract/expanded/Payload/usr/local/bin/scanline"
OURS_BIN="$REPO_ROOT/dist/bin/mcp-scanner-helper"

cmd="${1:-help}"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
dim() { printf "\033[2m%s\033[0m\n" "$*"; }
ok() { printf "  \033[32m✓\033[0m %s\n" "$*"; }
err() { printf "  \033[31m✗\033[0m %s\n" "$*"; }

ensure_sudo() {
  # Prompt once so subsequent sudo invocations in the script don't block.
  if ! sudo -n true 2>/dev/null; then
    bold "Caching sudo credential (needed for fs_usage + sample + log stream)"
    sudo -v
  fi
  # Keep alive in the background while we run
  ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!
}

stop_keepalive() {
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
}
trap stop_keepalive EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Run a single diagnostic capture

run_diagnostics() {
  local name="$1"
  local binary="$2"
  shift 2
  local -a bin_args=("$@")

  local out_dir="$OUTPUT_BASE/$name"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  bold "=== Diagnosing: $name ==="
  echo "Binary:  $binary"
  echo "Args:    ${bin_args[*]}"
  echo "Output:  $out_dir"
  echo ""

  if [[ ! -x "$binary" ]]; then
    err "Binary not found or not executable: $binary"
    return 1
  fi

  # Static info about the binary (no system state involved)
  bold "Phase 1: static binary metadata"
  codesign -dv --verbose=4 "$binary" >"$out_dir/codesign.txt" 2>&1 || true
  codesign -d --entitlements - --xml "$binary" >"$out_dir/entitlements.txt" 2>&1 || true
  codesign -d -r- "$binary" >"$out_dir/designated-requirement.txt" 2>&1 || true
  otool -L "$binary" >"$out_dir/loaded-libs.txt" 2>&1 || true
  otool -P "$binary" >"$out_dir/info-plist-embed.txt" 2>&1 || true
  otool -l "$binary" | grep -A4 "LC_BUILD_VERSION\|LC_RPATH\|LC_LOAD_DYLIB" >"$out_dir/load-commands.txt" 2>&1 || true
  ok "captured codesign/entitlements/loaded-libs"

  # Reset state: kill Image Capture and any AirScanScanner from prior runs
  pkill "Image Capture" 2>/dev/null || true
  pkill -f AirScanScanner 2>/dev/null || true
  sleep 0.5

  # Phase 2: start background captures
  bold "Phase 2: starting live captures"

  # log stream — broad predicate for everything ICA/security adjacent
  sudo /usr/bin/log stream --debug --info \
    --predicate 'process == "icdd" OR process == "amfid" OR process == "AirScanScanner" OR process == "trustd" OR process == "tccd" OR process == "syspolicyd" OR senderImagePath CONTAINS "ImageCapture" OR subsystem CONTAINS "com.apple.imagecapture" OR subsystem CONTAINS "com.apple.security.codesigning" OR subsystem CONTAINS "com.apple.amfi"' \
    >"$out_dir/log.log" 2>&1 &
  LOG_PID=$!
  ok "log stream started (pid $LOG_PID)"

  # fs_usage on icdd — every file/socket open made by icdd during the run
  sudo fs_usage -w -f filesys icdd AirScanScanner 2>/dev/null \
    >"$out_dir/fs_usage.log" &
  FS_PID=$!
  ok "fs_usage started on icdd + AirScanScanner (pid $FS_PID)"

  # Give captures a moment to ramp
  sleep 0.5

  # Phase 3: run the binary with a wall-clock timeout
  bold "Phase 3: running binary (max 35s)"
  date >"$out_dir/start-time.txt"
  ( "$binary" "${bin_args[@]}" >"$out_dir/stdout.log" 2>"$out_dir/stderr.log" ) &
  BIN_PID=$!
  echo "$BIN_PID" >"$out_dir/our-pid.txt"
  echo "  helper pid: $BIN_PID"

  # While the binary runs: grab launchctl + dynamic info about our process
  sleep 1
  if kill -0 "$BIN_PID" 2>/dev/null; then
    launchctl print "pid/$BIN_PID" >"$out_dir/launchctl.txt" 2>&1 || true
    vmmap --pages "$BIN_PID" >"$out_dir/vmmap.txt" 2>&1 || true
    ok "captured launchctl + vmmap for pid $BIN_PID"
  else
    err "binary exited before we could probe it"
  fi

  # Sample icdd while the request is in flight (denials happen <5s in)
  sleep 2
  ICDD_PID="$(pgrep -fx '/System/Library/Image Capture/Support/icdd' | head -1)"
  if [[ -n "$ICDD_PID" ]]; then
    sudo sample "$ICDD_PID" 3 -f "$out_dir/icdd-sample.txt" >/dev/null 2>&1 || true
    ok "sampled icdd (pid $ICDD_PID) for 3s"
  else
    err "icdd not running — cannot sample"
  fi

  # Wait for the binary to finish (or its 30s internal watchdog to fire)
  wait "$BIN_PID" 2>/dev/null || true
  date >"$out_dir/end-time.txt"

  # Phase 4: stop captures
  bold "Phase 4: stopping captures"
  sudo kill "$LOG_PID" 2>/dev/null || true
  sudo kill "$FS_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  ok "captures stopped"

  # Phase 5: quick summary
  bold "Phase 5: quick summary"
  echo "  log.log:     $(wc -l <"$out_dir/log.log" | tr -d ' ') lines"
  echo "  fs_usage:    $(wc -l <"$out_dir/fs_usage.log" | tr -d ' ') lines"
  echo "  stdout:      $(wc -l <"$out_dir/stdout.log" | tr -d ' ') lines"
  echo ""
  if grep -q "didOpenSessionWithError.*no error\|Endpoint.*Set\|running |.*AirScanScanner" "$out_dir/log.log" 2>/dev/null; then
    ok "SUCCESS: ICA session opened (look for 'running | AirScanScanner' or 'Endpoint Set')"
  else
    err "FAILED: ICA session did not open (no 'running |' line, denial silent)"
  fi
  echo ""
  echo "Outputs:"
  ls -la "$out_dir" | sed 's/^/  /'
  echo ""
  bold "Done. Now run: $0 diff"
}

# ─────────────────────────────────────────────────────────────────────────────
# Diff two runs

diff_results() {
  local a="${1:-scanline}"
  local b="${2:-ours}"
  local A="$OUTPUT_BASE/$a"
  local B="$OUTPUT_BASE/$b"

  if [[ ! -d "$A" || ! -d "$B" ]]; then
    err "Run both first: $0 scanline && $0 ours"
    return 1
  fi

  bold "=== Diff: $a vs $b ==="
  echo ""

  show_section() {
    local heading="$1"
    local file="$2"
    bold "── $heading ──"
    if command -v delta >/dev/null 2>&1; then
      diff -u "$A/$file" "$B/$file" | delta --no-gitconfig || true
    else
      diff -u "$A/$file" "$B/$file" 2>&1 | sed 's/^/  /' | head -80 || true
    fi
    echo ""
  }

  show_section "codesign (static signature properties)" "codesign.txt"
  show_section "entitlements (XML)" "entitlements.txt"
  show_section "designated requirement" "designated-requirement.txt"
  show_section "loaded libs (otool -L)" "loaded-libs.txt"
  show_section "embedded Info.plist (otool -P)" "info-plist-embed.txt"
  show_section "launchctl print pid/<bin>" "launchctl.txt"

  bold "── fs_usage delta: paths icdd accessed for $a but not for $b ──"
  grep -oE '"[^"]+"|/[A-Za-z0-9_./-]+' "$A/fs_usage.log" 2>/dev/null | sort -u >/tmp/ica-diag-paths-a.txt
  grep -oE '"[^"]+"|/[A-Za-z0-9_./-]+' "$B/fs_usage.log" 2>/dev/null | sort -u >/tmp/ica-diag-paths-b.txt
  comm -23 /tmp/ica-diag-paths-a.txt /tmp/ica-diag-paths-b.txt | head -30 | sed 's/^/  /'
  echo ""

  bold "── fs_usage delta: paths $b accessed but $a did not ──"
  comm -13 /tmp/ica-diag-paths-a.txt /tmp/ica-diag-paths-b.txt | head -30 | sed 's/^/  /'
  echo ""

  bold "── icdd sample (top frames) ──"
  echo "  $a:"
  grep -E "^\s+[0-9]+ " "$A/icdd-sample.txt" 2>/dev/null | head -15 | sed 's/^/    /'
  echo "  $b:"
  grep -E "^\s+[0-9]+ " "$B/icdd-sample.txt" 2>/dev/null | head -15 | sed 's/^/    /'
  echo ""

  bold "── log stream tail (last 15 lines each) ──"
  echo "  $a:"
  tail -15 "$A/log.log" 2>/dev/null | sed 's/^/    /'
  echo "  $b:"
  tail -15 "$B/log.log" 2>/dev/null | sed 's/^/    /'
  echo ""

  bold "Helpful follow-ups:"
  echo "  diff -u $A/log.log $B/log.log | less"
  echo "  diff -u $A/launchctl.txt $B/launchctl.txt | less"
  echo "  comm -23 <(sort -u <(grep -oE '/[A-Za-z0-9_./-]+' $A/fs_usage.log)) <(sort -u <(grep -oE '/[A-Za-z0-9_./-]+' $B/fs_usage.log))"
}

# ─────────────────────────────────────────────────────────────────────────────
# Entrypoint

case "$cmd" in
  ours)
    ensure_sudo
    run_diagnostics "ours" "$OURS_BIN" \
      "scan" "--params" '{"output_format":"pdf-searchable"}' "--out-dir" "/tmp/test-scan" "--verbose"
    ;;
  scanline)
    ensure_sudo
    if [[ ! -x "$SCANLINE_BIN" ]]; then
      err "scanline not extracted. Run first:"
      echo "    pkgutil --expand-full /Users/dougborg/Projects/scanline/scanline-2.3.pkg /tmp/scanline-extract/expanded"
      exit 1
    fi
    run_diagnostics "scanline" "$SCANLINE_BIN" \
      "-flatbed" "-scanner" "brother" "-verbose"
    ;;
  diff)
    diff_results "${2:-scanline}" "${3:-ours}"
    ;;
  clean)
    rm -rf "$OUTPUT_BASE"
    ok "removed $OUTPUT_BASE"
    ;;
  *)
    cat <<USAGE
Usage:
  $0 scanline    # run scanline with full instrumentation
  $0 ours        # run our binary with full instrumentation
  $0 diff        # diff the two captures
  $0 clean       # remove $OUTPUT_BASE

Workflow:
  1. $0 scanline             ← captures the reference
  2. $0 ours                 ← captures the broken case
  3. $0 diff                 ← shows what differs
  Iterate: change binary metadata, rebuild, rerun $0 ours, $0 diff.

Requires: sudo (cached at start).
USAGE
    ;;
esac
