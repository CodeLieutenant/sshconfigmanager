#!/usr/bin/env bash
# swift-format over the app's OWN sources.
#
# It has no exclude-path config: the set of files it looks at is exactly the set
# you hand it. That matters here, because Vendor/ holds ~3400 Swift files from
# forked upstream packages (swift-nio-ssh, swift-bcrypt-pbkdf). Reformatting
# those would wreck every future rebase against upstream, so the paths below are
# deliberately first-party only.
#
#   ./scripts/lint.sh          lint; non-zero exit on any finding (what CI runs)
#   ./scripts/lint.sh --fix    rewrite files in place, then lint what's left
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if command -v xcrun >/dev/null 2>&1; then
    SWIFT_FORMAT=(xcrun swift-format)
else
    SWIFT_FORMAT=(swift format)
fi

# First-party only. Vendor/, build*/, DerivedData/ and dist/ are excluded by
# omission — do not replace this with a bare `.`.
TARGETS=(
    sshconfigmanager
    sshconfigmanagerTests
    sshconfigmanagerUITests
    Packages/SSHConfigKit/Sources
    Packages/SSHConfigKit/Tests
    Packages/SSHConfigMacUI/Sources
    Packages/SSHConfigMacUI/Tests
    Tools/StoreFrames/Sources
)

# `swift format` resolves .swift-format by walking up from each input file, so
# every target below picks up the root .swift-format.
if [[ "${1:-}" == "--fix" ]]; then
    echo "swift-format: rewriting ${#TARGETS[@]} source trees in place"
    "${SWIFT_FORMAT[@]}" format --in-place --parallel --recursive "${TARGETS[@]}"
fi

echo "swift-format: linting ${#TARGETS[@]} source trees"
# --strict promotes every finding to an error so the exit code is usable as a
# CI gate; without it swift-format prints warnings and still exits 0.
"${SWIFT_FORMAT[@]}" lint --strict --parallel --recursive "${TARGETS[@]}"

echo "swift-format: clean"
