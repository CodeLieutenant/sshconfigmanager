#!/usr/bin/env bash
#
# release.sh — Cut a release of sshconfigmanager through fastlane.
#
# Two mental models, mirroring how App Store Connect versions a build:
#
#   • Sandbox / TestFlight  → bump the BUILD NUMBER only (marketing version
#     stays put). Every upload of a given marketing version needs a higher
#     build, so this is the routine "ship another beta" loop.
#       CURRENT_PROJECT_VERSION:  N → N+1
#
#   • Real app / App Store   → bump the BUILD NUMBER by default (the marketing
#     version stays put, like TestFlight). Advance the user-visible X.Y.Z only
#     when you explicitly ask for it (--bump patch|minor|major, or --set). The
#     build number keeps counting up across the version advance.
#       MARKETING_VERSION:        unchanged | bumped (--bump/--set)
#       CURRENT_PROJECT_VERSION:  N → N+1
#
# The build number is one global counter for the bundle id, not a per-version
# train. The Mac App Store rejects (90061) any upload whose CFBundleVersion is
# not higher than every build previously uploaded, whatever its MARKETING_VERSION.
# If you cut builds on a release branch, merge that counter back into main before
# you upload from main.
#
# Versions live in sshconfigmanager.xcodeproj/project.pbxproj (one value per
# build config; this script rewrites every occurrence so they stay in lockstep).
# App Store Connect / notarization auth comes from ./.release (sourced if
# present) — the same App Store Connect API key the Fastfile reads from env.
#
# Usage:
#   ./scripts/release.sh testflight              # +build, upload to TestFlight
#   ./scripts/release.sh beta                    #   (alias of testflight)
#   ./scripts/release.sh release                 # +build only (version unchanged) → App Store
#   ./scripts/release.sh release --bump patch     # advance patch (x.y.Z), build → 1 → App Store
#   ./scripts/release.sh release --bump minor     # advance minor (x.Y.0), build → 1 → App Store
#   ./scripts/release.sh release --bump major     # advance major (X.0.0), build → 1 → App Store
#   ./scripts/release.sh release --set 1.2.0      # set explicit version, build → 1 → App Store
#   ./scripts/release.sh dmg                      # +build, notarized Developer ID .dmg
#
# Options:
#   --bump PART   Advance the marketing version (patch | minor | major) — only for
#                 'release'. The build number still advances by one.
#   --dry-run     Compute and print the version changes, then stop (no edit,
#                 no build, no upload). Great for sanity-checking a bump.
#   --no-bump     Skip version edits entirely; build/upload the current values
#                 (e.g. to re-run after a transient upload failure).
#   --build N     Force the build number to N (overrides the +1 rule).
#   --commit      git-commit the pbxproj version change (only that file).
#   --tag         Also create an annotated git tag (v<MARKETING_VERSION> for
#                 'release'; v<MARKETING_VERSION>+build.N otherwise). Implies
#                 --commit.
#   -h, --help    Show this header.
#
set -euo pipefail

# --- Config -----------------------------------------------------------------
SCHEME="sshconfigmanager"

# Resolve repo root (this script lives in <root>/scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

PBXPROJ="$ROOT_DIR/${SCHEME}.xcodeproj/project.pbxproj"

# --- Parse args -------------------------------------------------------------
COMMAND=""
BUMP_PART=""          # for 'release': empty = build-only; patch | minor | major to advance
SET_VERSION=""        # for 'release --set X.Y.Z'
DRY_RUN=0
NO_BUMP=0
FORCE_BUILD=""
DO_COMMIT=0
DO_TAG=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^#\{1,\} \{0,1\}//;s/^#$//'; }

# First positional is the command; the rest are sub-args / flags.
while [[ $# -gt 0 ]]; do
  case "$1" in
    testflight|beta|release|dmg)
      [[ -z "$COMMAND" ]] && COMMAND="$1" || { echo "Unexpected extra command: $1" >&2; exit 2; }
      ;;
    --bump)             BUMP_PART="${2:?--bump needs patch|minor|major}"; shift
                        [[ "$BUMP_PART" =~ ^(patch|minor|major)$ ]] || { echo "ERROR: --bump expects patch|minor|major, got '$BUMP_PART'" >&2; exit 2; } ;;
    --set)              SET_VERSION="${2:?--set needs a version}"; shift ;;
    --build)            FORCE_BUILD="${2:?--build needs a number}"; shift ;;
    --dry-run)          DRY_RUN=1 ;;
    --no-bump)          NO_BUMP=1 ;;
    --commit)           DO_COMMIT=1 ;;
    --tag)              DO_TAG=1; DO_COMMIT=1 ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; echo "Run with --help for usage." >&2; exit 2 ;;
  esac
  shift
done

if [[ -z "$COMMAND" ]]; then
  echo "ERROR: no command given (testflight | beta | release | dmg)." >&2
  echo "Run with --help for usage." >&2
  exit 2
fi
[[ "$COMMAND" == "beta" ]] && COMMAND="testflight"

# --- Version helpers --------------------------------------------------------
get_marketing() { grep -m1 -E '^[[:space:]]*MARKETING_VERSION = ' "$PBXPROJ" | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/'; }
get_build()     { grep -m1 -E '^[[:space:]]*CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed -E 's/.*CURRENT_PROJECT_VERSION = ([^;]+);.*/\1/'; }

# Rewrite every occurrence so all build configs share one value.
set_marketing() { perl -0pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $1;/g" "$PBXPROJ"; }
set_build()     { perl -0pi -e "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $1;/g" "$PBXPROJ"; }

bump_semver() {  # $1 = x.y.z, $2 = patch|minor|major  →  echoes new x.y.z
  local v="$1" part="$2" major minor patch
  IFS=. read -r major minor patch <<<"$v"
  : "${major:=0}" "${minor:=0}" "${patch:=0}"
  case "$part" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  echo "${major}.${minor}.${patch}"
}

CUR_MARKETING="$(get_marketing)"
CUR_BUILD="$(get_build)"

# --- Compute the target versions -------------------------------------------
NEW_MARKETING="$CUR_MARKETING"
NEW_BUILD="$CUR_BUILD"

if [[ "$NO_BUMP" -eq 0 ]]; then
  if [[ "$COMMAND" == "release" || "$COMMAND" == "testflight" ]]; then
    if [[ -n "$SET_VERSION" ]]; then
      [[ "$SET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: --set expects X.Y.Z, got '$SET_VERSION'" >&2; exit 2; }
      NEW_MARKETING="$SET_VERSION"
    elif [[ -n "$BUMP_PART" ]]; then
      NEW_MARKETING="$(bump_semver "$CUR_MARKETING" "$BUMP_PART")"
    fi
    # else: leave NEW_MARKETING == CUR_MARKETING (build-only release)
  fi

  # Build number: always current + 1, never reset. The Mac App Store compares
  # CFBundleVersion against every build ever uploaded for the bundle id, not just
  # the ones under the same MARKETING_VERSION — a reset gets rejected with 90061.
  if [[ -n "$FORCE_BUILD" ]]; then
    NEW_BUILD="$FORCE_BUILD"
  else
    NEW_BUILD=$((CUR_BUILD + 1))
  fi
fi

# --- Show the plan ----------------------------------------------------------
echo "==> Cutting '${COMMAND}' release"
echo "    MARKETING_VERSION:        ${CUR_MARKETING} → ${NEW_MARKETING}"
echo "    CURRENT_PROJECT_VERSION:  ${CUR_BUILD} → ${NEW_BUILD}"
case "$COMMAND" in
  testflight) echo "    Channel: TestFlight (fastlane mac beta)";;
  release)    echo "    Channel: App Store Connect (fastlane mac release)";;
  dmg)        echo "    Channel: Developer ID notarized .dmg (fastlane mac developerid)";;
esac

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> --dry-run: stopping before edits/build."
  exit 0
fi

# --- Apply the bump ---------------------------------------------------------
if [[ "$NO_BUMP" -eq 0 ]]; then
  [[ "$NEW_MARKETING" != "$CUR_MARKETING" ]] && set_marketing "$NEW_MARKETING"
  set_build "$NEW_BUILD"
  echo "==> Updated $PBXPROJ"
fi

# --- App Store Connect / notarization credentials ---------------------------
if [[ -f "$ROOT_DIR/.release" ]]; then
  echo "==> Sourcing .release for App Store Connect API key"
  set -a; # shellcheck disable=SC1091
  source "$ROOT_DIR/.release"; set +a
elif [[ -z "${ASC_KEY_ID:-}" ]]; then
  echo "WARNING: no ./.release and ASC_KEY_ID is unset — fastlane auth may fail." >&2
fi
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"

# --- Run fastlane -----------------------------------------------------------
case "$COMMAND" in
  testflight) LANE="beta" ;;
  release)    LANE="release" ;;
  dmg)        LANE="developerid" ;;
esac

echo "==> bundle exec fastlane mac ${LANE}"
bundle exec fastlane mac "$LANE"

# --- Optional commit / tag --------------------------------------------------
if [[ "$DO_COMMIT" -eq 1 && "$NO_BUMP" -eq 0 ]]; then
  echo "==> Committing version bump"
  git add "$PBXPROJ"
  if [[ "$COMMAND" == "release" ]]; then
    MSG="Release ${NEW_MARKETING} (build ${NEW_BUILD})"
  else
    MSG="Build ${NEW_MARKETING} (build ${NEW_BUILD}) [${COMMAND}]"
  fi
  git commit -m "$MSG"

  if [[ "$DO_TAG" -eq 1 ]]; then
    # A version-advancing release tags v<X.Y.Z>; a build-only release (or any
    # non-release channel) tags v<X.Y.Z>+build.N so it stays unique.
    if [[ "$COMMAND" == "release" && "$NEW_MARKETING" != "$CUR_MARKETING" ]]; then
      TAG="v${NEW_MARKETING}"
    else
      TAG="v${NEW_MARKETING}+build.${NEW_BUILD}"
    fi
    echo "==> Tagging ${TAG}"
    git tag -a "$TAG" -m "$MSG"
    echo "    Push with: git push origin HEAD ${TAG}"
  fi
fi

echo "Done."
