#!/usr/bin/env bash
#
# Build (and optionally test) the platform-neutral Swift packages against Linux,
# inside the official Swift container. This is the only way to prove the Linux
# port keeps working from a Mac, so CI and local checks both run it.
#
# Usage:
#   ./scripts/linux-build.sh                 # build every Linux-facing package
#   ./scripts/linux-build.sh --test          # build, then run the test suites
#   ./scripts/linux-build.sh kit             # one package only (kit|bcrypt)
#   ./scripts/linux-build.sh --test kit
#
# The sources are copied into the container rather than bind-mounted read-write,
# so a Linux .build directory never lands in the working tree and never fights
# with the macOS one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE="${SWIFT_LINUX_IMAGE:-swift:6.2-noble}"

RUN_TESTS=0
PACKAGES=()
for arg in "$@"; do
    case "$arg" in
        --test) RUN_TESTS=1 ;;
        kit | bcrypt) PACKAGES+=("$arg") ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done
if [ ${#PACKAGES[@]} -eq 0 ]; then
    PACKAGES=(bcrypt kit)
fi

path_for() {
    case "$1" in
        bcrypt) echo "Vendor/swift-bcrypt-pbkdf" ;;
        kit) echo "Packages/SSHConfigKit" ;;
    esac
}

if ! docker info >/dev/null 2>&1; then
    echo "error: no Docker daemon. Start Docker (or OrbStack) and retry." >&2
    exit 1
fi

status=0
for pkg in "${PACKAGES[@]}"; do
    rel="$(path_for "$pkg")"
    echo ""
    echo "==> $rel  (${IMAGE}, $([ "$RUN_TESTS" -eq 1 ] && echo 'swift test' || echo 'swift build'))"
    verb=$([ "$RUN_TESTS" -eq 1 ] && echo test || echo build)
    # `.build` and `.swiftpm` hold macOS artifacts; excluding them keeps the copy
    # small and stops SwiftPM from reading a manifest cache built for a different
    # host triple.
    if docker run --rm \
        -v "$ROOT_DIR/$rel:/src:ro" \
        -v "$ROOT_DIR/Vendor:/vendor:ro" \
        "$IMAGE" bash -euo pipefail -c "
            # Local path dependencies are relative ('../../Vendor/...'), so the copy
            # has to sit at the same depth under /work that it does under macos.
            mkdir -p '/work/$rel' /work/Vendor
            find /src -mindepth 1 -maxdepth 1 -not -name .build -not -name .swiftpm -exec cp -r {} '/work/$rel/' \;
            cp -r /vendor/. /work/Vendor/
            find /work \( -name .build -o -name .swiftpm \) -prune -exec rm -rf {} +
            cd '/work/$rel'
            # Capture the whole log, then surface the error lines. A bare 'tail' buries
            # the first error under a wall of Sendable warnings, and that error line is
            # the only part worth reading. 'set +e' so the summary always prints.
            set +e
            swift $verb >/tmp/out.log 2>&1
            rc=\$?
            tail -25 /tmp/out.log
            # ': error:' rather than 'error:', so a diagnostic is matched but the word
            # inside a quoted message in the source listing is not.
            if grep -q ': error:' /tmp/out.log; then
                echo ''
                echo '--- errors ---'
                grep ': error:' /tmp/out.log | sort -u
            fi
            exit \$rc
        "; then
        echo "    OK"
    else
        echo "    FAILED: $rel" >&2
        status=1
    fi
done

exit $status
