#!/usr/bin/env bash
#
# screenshots.sh — capture RAW app-window screenshots by running the
# ScreenshotUITests UI test against a SIGNED build, then extract the named PNG
# attachments from the resulting .xcresult into store-assets/raw/en-US/.
#
# This script only captures. It does not pad, resize or caption. The finished
# App Store frames (background, headline, sub-caption) are built from these raw
# files by ./scripts/store-frames.sh, which is what writes
# fastlane/screenshots/en-US/ for `fastlane deliver`.
#
# Requirements:
#   • An interactive GUI login session (XCUITest drives the real window).
#   • A signed build — do NOT pass CODE_SIGNING_ALLOWED=NO (an unsigned runner is
#     killed before it can connect).
#   • xcparse for attachment extraction:  brew install chargepoint/xcparse/xcparse
#
# Usage:  ./scripts/screenshots.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="sshconfigmanager.xcodeproj"
SCHEME="sshconfigmanager"
RESULT_BUNDLE="build/screenshots.xcresult"
OUT_DIR="store-assets/raw/en-US"
TMP_DIR="build/screenshots-extract"

echo "==> Cleaning previous artifacts"
rm -rf "$RESULT_BUNDLE" "$TMP_DIR" "$OUT_DIR"
mkdir -p "$OUT_DIR" "$TMP_DIR"

echo "==> Running ScreenshotUITests (signed build, GUI session required)"
# Don't let a single failed shot abort extraction — the .xcresult still holds the
# attachments that did capture. Record the status and continue.
set +e
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -only-testing:sshconfigmanagerUITests/ScreenshotUITests \
  -resultBundlePath "$RESULT_BUNDLE" \
  -allowProvisioningUpdates
TEST_STATUS=$?
set -e
if [[ $TEST_STATUS -ne 0 ]]; then
  echo "    NOTE: the test reported a failure (status $TEST_STATUS) — extracting" >&2
  echo "    whatever screenshots were captured anyway." >&2
fi

if ! command -v xcparse >/dev/null 2>&1; then
  echo "ERROR: xcparse not found. Install it with:" >&2
  echo "       brew install chargepoint/xcparse/xcparse" >&2
  echo "The run succeeded — attachments are in $RESULT_BUNDLE; re-run after installing." >&2
  exit 1
fi

echo "==> Extracting attachments from $RESULT_BUNDLE"
xcparse screenshots "$RESULT_BUNDLE" "$TMP_DIR" >/dev/null

NAMES=(01-host-detail 02-add-setting 03-groups 04-tunnels 05-keys \
       06-agent 07-known-hosts 08-version-history)

echo "==> Collecting named screenshots into $OUT_DIR"
for name in "${NAMES[@]}"; do
  # xcparse writes "<attachment-name>_<uuid>.png" (possibly nested); newest match.
  match="$(find "$TMP_DIR" -name "*$name*.png" -print0 2>/dev/null \
           | xargs -0 ls -t 2>/dev/null | head -n1 || true)"
  if [[ -n "$match" ]]; then
    cp "$match" "$OUT_DIR/$name.png"
  else
    echo "    WARNING: no attachment found for '$name'" >&2
  fi
done

# Report what landed, at whatever size it came out. Padding and resizing are
# deliberately NOT done here: storeframes crops each window out of its capture
# and composes it onto the App Store canvas itself, so a padded source would only
# give it a border to detect and throw away.
echo "==> Raw captures in $OUT_DIR"
for name in "${NAMES[@]}"; do
  f="$OUT_DIR/$name.png"
  [[ -f "$f" ]] || continue
  dims="$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixel/ {printf "%sx", $2}')"
  echo "    $name.png  (${dims%x}px)"
done

echo ""
echo "Done. Next: ./scripts/store-frames.sh --open"
echo "That builds the captioned App Store frames into fastlane/screenshots/en-US."
