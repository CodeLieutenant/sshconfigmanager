#!/usr/bin/env bash
#
# record-tunnel-demo.sh — App Store preview video: in-process SSH tunnel showcase.
#
# Drives TunnelDemoUITests through a ~26 s walkthrough of the tunnel lifecycle:
#   - Pre-seeded Active tunnel (Postgres local forward, 2:07 uptime)
#   - Stop → console logs "Stopped"
#   - Start → DemoTunnelEngine emits lifecycle events, console fills, Active
#   - Switch to Redis local forward → Start → Active
#   - Switch to SOCKS5 dynamic proxy → Start → Active
# Records ONLY the app window via screencapture -l<winid> (no desktop, no
# overlay), then encodes to H.264 at the App Store spec (1920×1080, ≤29s).
#
# Usage:
#   ./scripts/record-tunnel-demo.sh
#   RECORD_SECONDS=35 ./scripts/record-tunnel-demo.sh
#
# Output:
#   build/preview/tunnel-demo.mov          raw window capture (gitignored)
#   build/preview/tunnel-demo.mp4          App-Store-ready H.264 (gitignored)
#   fastlane/previews/en-US/tunnel-demo.mp4  versioned copy (committed)
#
# Upload all three preview videos at once:
#   cd macos && bundle exec fastlane upload_all_previews
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="sshconfigmanager.xcodeproj"
SCHEME="sshconfigmanager"
OUT_DIR="build/preview"
RAW="$OUT_DIR/tunnel-demo.mov"
OUT="$OUT_DIR/tunnel-demo.mp4"
RECORD_SECONDS="${RECORD_SECONDS:-33}"
TARGET="${TARGET:-1920x1080}"
LOG="$OUT_DIR/tunnel-demo-test.log"
FADE_IN="${FADE_IN:-0.4}"
FADE_OUT="${FADE_OUT:-0.8}"

mkdir -p "$OUT_DIR"

# ── Pre-flight checks ────────────────────────────────────────────────────────
command -v ffmpeg >/dev/null 2>&1 \
  || { echo "ERROR: ffmpeg not found — brew install ffmpeg" >&2; exit 1; }

# ── CoreGraphics window-ID lookup ────────────────────────────────────────────
find_window_id() {
  swift - <<'SWIFT' 2>/dev/null || true
import CoreGraphics
let list = (CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]]) ?? []
var best = (id: 0, area: 0.0)
for w in list where (w[kCGWindowOwnerName as String] as? String) == "SSH Config Manager" {
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
          let width = b["Width"] as? Double, let height = b["Height"] as? Double,
          let n = w[kCGWindowNumber as String] as? Int else { continue }
    let area = width * height
    if area > best.area { best = (n, area) }
}
print(best.id)
SWIFT
}

# ── Build & run the UI test ──────────────────────────────────────────────────
echo "==> Building TunnelDemoUITests (signed)"
xcodebuild build-for-testing \
  -project "$PROJECT" -scheme "$SCHEME" \
  -destination 'platform=macOS' -allowProvisioningUpdates \
  2>&1 | grep -E 'error:|warning:|Build succeeded|BUILD FAILED' || true

pkill -f "SSH Config Manager.app/Contents/MacOS" 2>/dev/null || true
sleep 1
rm -f "$RAW"

echo "==> Launching tunnel demo walkthrough (TunnelDemoUITests)"
xcodebuild test-without-building \
  -project "$PROJECT" -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -only-testing:sshconfigmanagerUITests/TunnelDemoUITests \
  >"$LOG" 2>&1 &
TEST_PID=$!

# ── Wait for the app window to appear ───────────────────────────────────────
echo "==> Waiting for app window…"
WIN_ID=""
for _ in $(seq 1 120); do
  WIN_ID="$(find_window_id)"
  [[ -n "$WIN_ID" && "$WIN_ID" != "0" ]] && break
  sleep 0.5
done

if [[ -z "$WIN_ID" || "$WIN_ID" == "0" ]]; then
  echo "ERROR: app window never appeared — check $LOG" >&2
  kill "$TEST_PID" 2>/dev/null || true
  tail -30 "$LOG" >&2
  exit 1
fi

# ── Record ──────────────────────────────────────────────────────────────────
echo "==> Recording window $WIN_ID for ${RECORD_SECONDS}s (window-only, no desktop)"
screencapture -v -V"$RECORD_SECONDS" -o -x -l"$WIN_ID" "$RAW"

wait "$TEST_PID" 2>/dev/null || true

if [[ ! -s "$RAW" ]]; then
  echo "ERROR: no recording produced. Grant Screen Recording to Terminal in" >&2
  echo "       System Settings › Privacy & Security › Screen Recording." >&2
  exit 1
fi

# ── Encode to App Store preview spec ────────────────────────────────────────
echo "==> Encoding to H.264 ${TARGET} with fade-in/out (App Store preview spec)"
W="${TARGET%x*}"; H="${TARGET#*x}"

APP_STORE_MAX="${APP_STORE_MAX:-29}"
RAW_DURATION="$(ffprobe -v error -select_streams v:0 \
  -show_entries format=duration -of csv=p=0 "$RAW" 2>/dev/null || echo "$RECORD_SECONDS")"
CLIP_DURATION="$(echo "$RAW_DURATION $APP_STORE_MAX" | awk '{print ($1 < $2) ? $1 : $2}')"
FADE_OUT_ST="$(echo "$CLIP_DURATION $FADE_OUT" | awk '{printf "%.3f", $1 - $2}')"

VF="scale=${W}:${H}:force_original_aspect_ratio=decrease:flags=lanczos,\
pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:color=black,\
fps=30,\
format=yuv420p,\
fade=t=in:st=0:d=${FADE_IN},\
fade=t=out:st=${FADE_OUT_ST}:d=${FADE_OUT}"

ffmpeg -hide_banner -loglevel error -i "$RAW" \
  -t "$CLIP_DURATION" \
  -vf "$VF" \
  -c:v libx264 -profile:v high -crf 18 -movflags +faststart -an \
  -y "$OUT"

# ── Version to fastlane/previews ─────────────────────────────────────────────
VERSIONED_DIR="$ROOT_DIR/fastlane/previews/en-US"
mkdir -p "$VERSIONED_DIR"
cp "$OUT" "$VERSIONED_DIR/$(basename "$OUT")"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
FILESIZE="$(du -sh "$OUT" | cut -f1)"
echo "Done:"
echo "  raw       : $RAW  (${RAW_DURATION}s)"
echo "  mp4       : $OUT  (${TARGET}, ${CLIP_DURATION}s clamped, ${FILESIZE})"
echo "  versioned : $VERSIONED_DIR/$(basename "$OUT")"
echo ""
echo "Commit fastlane/previews/en-US/ then upload:"
echo "  cd macos && bundle exec fastlane upload_all_previews"
