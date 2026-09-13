#!/usr/bin/env bash
#
# install-local.sh — Build a Release build of sshconfigmanager and install it
# into /Applications on this Mac.
#
# The app is development-signed (Apple Development cert + auto-managed
# provisioning, via -allowProvisioningUpdates). This is required: the
# keychain-access-groups entitlement can't be satisfied by ad-hoc
# "Sign to Run Locally" signing. It runs on this Mac (and the team's
# registered Macs); it is not notarized and will be blocked elsewhere.
# Needs an Apple account in Xcode → Settings → Accounts for your team.
#
# Usage:
#   ./scripts/install-local.sh           # rebuild + install + launch
#   ./scripts/install-local.sh --no-open # rebuild + install, don't launch
#   ./scripts/install-local.sh --clean   # remove build dir before building
#
set -euo pipefail

# --- Config -----------------------------------------------------------------
SCHEME="sshconfigmanager"
CONFIGURATION="Release"
APP_NAME="SSH Config Manager.app"
INSTALL_DIR="$HOME/Applications"

# Resolve repo root (this script lives in <root>/scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="$ROOT_DIR/${SCHEME}.xcodeproj"
DERIVED="$ROOT_DIR/build_install"
BUILT_APP="$DERIVED/Build/Products/$CONFIGURATION/$APP_NAME"
DEST_APP="$INSTALL_DIR/$APP_NAME"

# --- Flags ------------------------------------------------------------------
OPEN_AFTER=1
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_AFTER=0 ;;
    --clean)   CLEAN=1 ;;
    -h|--help)
      sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- Quit any running instance ---------------------------------------------
echo "==> Quitting any running instance…"
osascript -e "quit app \"$SCHEME\"" 2>/dev/null || true
sleep 1
pkill -f "$DEST_APP" 2>/dev/null || true
sleep 1

# --- Build ------------------------------------------------------------------
if [[ "$CLEAN" -eq 1 ]]; then
  echo "==> Cleaning ${DERIVED}…"
  rm -rf "$DERIVED"
fi

echo "==> Building $SCHEME ($CONFIGURATION)…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build

if [[ ! -d "$BUILT_APP" ]]; then
  echo "ERROR: expected app not found at $BUILT_APP" >&2
  exit 1
fi

# --- Install ----------------------------------------------------------------
echo "==> Installing to ${DEST_APP}…"
rm -rf "$DEST_APP"
cp -R "$BUILT_APP" "$INSTALL_DIR/"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

VERSION="$(defaults read "$DEST_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")"
BUNDLE_ID="$(defaults read "$DEST_APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "?")"
echo "==> Installed $BUNDLE_ID v$VERSION"

# --- Launch -----------------------------------------------------------------
if [[ "$OPEN_AFTER" -eq 1 ]]; then
  echo "==> Launching…"
  open "$DEST_APP"
fi

echo "Done."
