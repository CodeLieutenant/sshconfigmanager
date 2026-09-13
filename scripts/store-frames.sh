#!/usr/bin/env bash
#
# store-frames.sh — build the App Store screenshots from raw window captures.
#
# Raw captures live in store-assets/raw/<locale>/ and are never edited. Every
# frame is described in store-assets/frames.json: the headline, the sub-caption,
# the layout, the crop. To change a caption, edit that file and run this again.
#
# Usage:
#   ./scripts/store-frames.sh                    # render every frame at 2880x1800
#   ./scripts/store-frames.sh --only tunnels     # render one, for a fast look
#   ./scripts/store-frames.sh --probe            # report the window box per source
#   ./scripts/store-frames.sh --list             # print the shot table and copy
#   ./scripts/store-frames.sh --open             # render, then open the output
#   LOCALE=de-DE ./scripts/store-frames.sh       # a different locale's captures
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

LOCALE="${LOCALE:-en-US}"
SPEC="${SPEC:-store-assets/frames.json}"
RAW="${RAW:-store-assets/raw/$LOCALE}"
OUT="${OUT:-fastlane/screenshots/$LOCALE}"
TOOL_DIR="Tools/StoreFrames"

OPEN_AFTER=0
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--open" ]]; then OPEN_AFTER=1; else ARGS+=("$arg"); fi
done

if [[ ! -d "$RAW" ]]; then
  echo "ERROR: no raw captures in $RAW" >&2
  echo "       Run ./scripts/screenshots.sh first, or set RAW=<dir>." >&2
  exit 1
fi

echo "==> Building storeframes"
swift build -c release --package-path "$TOOL_DIR" >/dev/null

BIN="$(swift build -c release --package-path "$TOOL_DIR" --show-bin-path)/storeframes"

echo "==> Rendering frames ($LOCALE)"
"$BIN" --spec "$SPEC" --raw "$RAW" --out "$OUT" ${ARGS[@]+"${ARGS[@]}"}

if [[ $OPEN_AFTER -eq 1 ]]; then open "$OUT"; fi
