#!/usr/bin/env bash
#
# Build sshmanager in a container, so the binary's compatibility floor is a
# decision rather than an accident of whichever machine ran the build.
#
# Read this before changing the base image:
#
#   glibc is NOT what limits this app. Adwaita for Swift calls adw_bottom_sheet_*,
#   which arrived in libadwaita 1.6 (GNOME 47). A distribution older than that
#   cannot run the binary whatever its glibc version is. So the base image is the
#   OLDEST image that still carries libadwaita 1.6, and that choice fixes the
#   glibc floor as a side effect.
#
#   Users on anything older get the Flatpak, which carries its own GNOME runtime.
#
# Usage:
#   ./scripts/release-build.sh            # build, then report the floor
#   ./scripts/release-build.sh --report   # report the floor of an existing build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"

# Ubuntu 24.10 is the oldest release carrying libadwaita 1.6. It is out of
# support, so the archive lives on old-releases; pin the base image digest-free
# but keep the sources rewrite below with it.
BASE_IMAGE="${SSHMANAGER_BASE_IMAGE:-ubuntu:24.10}"
SWIFT_VERSION="${SSHMANAGER_SWIFT_VERSION:-6.3.3}"
OUTPUT="$ROOT_DIR/.build/release-container/sshmanager"

report_floor() {
    local binary="$1"
    [ -x "$binary" ] || {
        echo "no binary at $binary" >&2
        exit 1
    }
    echo ""
    echo "=== compatibility floor of $(basename "$binary") ==="
    local glibc
    glibc="$(objdump -T "$binary" | grep -oP 'GLIBC_\d+\.\d+' | sort -uV | tail -1)"
    echo "  glibc:      ${glibc#GLIBC_}"
    echo "  libadwaita: 1.6   (adw_bottom_sheet_*, fixed by the source, not the build)"
    echo "  gtk4:       4.16  (ships with libadwaita 1.6)"
    echo ""
    echo "  Runs on:    Ubuntu 24.10+, Debian 13+, Fedora 41+, and any distribution"
    echo "              with GNOME 47 or newer."
    echo "  Older:      use the Flatpak — it carries its own GNOME runtime."
    echo ""
}

if [ "${1:-}" = "--report" ]; then
    report_floor "$OUTPUT"
    exit 0
fi

if ! docker info >/dev/null 2>&1; then
    echo "error: no Docker daemon. Start Docker and retry." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

# The build needs this package, Packages/SSHConfigKit and Vendor/, so the whole
# repository is mounted read-only and those trees are copied inside.
docker run --rm \
    -v "$REPO_ROOT:/src:ro" \
    -v "$(dirname "$OUTPUT"):/out" \
    "$BASE_IMAGE" bash -euo pipefail -c "
        export DEBIAN_FRONTEND=noninteractive
        # 24.10 is end of life, so its archive moved to old-releases.
        if grep -q 'oracular' /etc/os-release 2>/dev/null; then
            sed -i 's|//archive.ubuntu.com|//old-releases.ubuntu.com|g; s|//security.ubuntu.com|//old-releases.ubuntu.com|g' \
                /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
        fi
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends \
            curl ca-certificates gnupg binutils git \
            libgtk-4-dev libadwaita-1-dev pkg-config \
            libcurl4-openssl-dev libxml2 libz3-dev \
            libncurses6 libpython3-dev tzdata >/dev/null

        echo '==> libadwaita' \$(pkg-config --modversion libadwaita-1) 'gtk4' \$(pkg-config --modversion gtk4)

        # The Swift toolchain for the closest supported Ubuntu. Its own glibc
        # requirement is below the base image's, which is what makes this work.
        curl -fsSL -o /tmp/swift.tar.gz \
            https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04.tar.gz
        mkdir -p /opt/swift
        tar -xzf /tmp/swift.tar.gz -C /opt/swift --strip-components=1
        export PATH=/opt/swift/usr/bin:\$PATH
        swift --version

        mkdir -p /work
        cp -r /src/Packages /work/Packages
        cp -r /src/Vendor /work/Vendor
        find /work -name .build -prune -exec rm -rf {} + 2>/dev/null || true
        find /work -name .swiftpm -prune -exec rm -rf {} + 2>/dev/null || true

        cd /work/Packages/SSHManagerUI
        swift build -c release -Xswiftc -static-stdlib
        cp .build/release/sshmanager /out/sshmanager
        strip /out/sshmanager
        echo '==> built'
    "

report_floor "$OUTPUT"
