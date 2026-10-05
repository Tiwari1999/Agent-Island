#!/bin/bash

# Get this Mac what the build needs, installing or updating it on the spot; commands come from PATH so tests can stub them.
set -euo pipefail

MIN_MACOS=14
MIN_SWIFT="${AGENTISLAND_MIN_SWIFT:-5.10}"
# Without a terminal nobody can answer a prompt or type a password, so say what to run instead.
interactive() { [ -t 0 ] && [ -z "${AGENTISLAND_NONINTERACTIVE:-}" ]; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
swift_version() { swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1; }

# Apple lists Command Line Tools in Software Update only while this marker exists.
clt_label() {
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    softwareupdate --list 2>/dev/null | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p' | sort -V | tail -1
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
}

install_clt_update() {
    local label; label="$(clt_label)"
    if [ -z "$label" ]; then
        echo "!! Software Update offers no newer Command Line Tools for this Mac." >&2
        echo "!! Update macOS, or install them from https://developer.apple.com/download/all/" >&2
        exit 1
    fi
    if ! interactive; then
        echo "!! run: sudo softwareupdate -i \"$label\"   then re-run ./install.sh" >&2; exit 1
    fi
    echo "==> installing $label (macOS asks for your password)"
    sudo softwareupdate -i "$label"
}

wait_for_clt() {
    echo "==> waiting for the Command Line Tools installer to finish (click Install in Apple's dialog)"
    for _ in $(seq 1 360); do
        xcode-select -p >/dev/null 2>&1 && [ -n "$(swift_version)" ] && return 0
        sleep 5
    done
    echo "!! Command Line Tools still missing after 30 minutes; re-run ./install.sh once they are in." >&2
    exit 1
}

# A half-upgraded install (leftovers from an older Swift) fixes only by a clean reinstall.
if [ "${1:-}" = "--reinstall-clt" ]; then
    interactive || { echo "!! run: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install" >&2; exit 1; }
    read -r -p "Reinstall Apple's Command Line Tools now? It takes a few minutes. [y/N] " ok
    [ "$ok" = y ] || [ "$ok" = Y ] || exit 1
    sudo rm -rf /Library/Developer/CommandLineTools
    xcode-select --install 2>/dev/null || true
    wait_for_clt
    exit 0
fi

macos="$(sw_vers -productVersion)"
if ! ver_ge "$macos" "$MIN_MACOS"; then
    echo "!! Agent Island needs macOS $MIN_MACOS Sonoma or later; this Mac runs $macos." >&2
    exit 1
fi

if ! xcode-select -p >/dev/null 2>&1 || [ -z "$(swift_version)" ]; then
    echo "==> Apple's Command Line Tools are not installed; starting their installer"
    if ! interactive; then echo "!! run: xcode-select --install   then re-run ./install.sh" >&2; exit 1; fi
    xcode-select --install 2>/dev/null || true
    wait_for_clt
fi

have="$(swift_version)"
if ! ver_ge "$have" "$MIN_SWIFT"; then
    echo "==> Swift $have is older than the $MIN_SWIFT this build needs; updating Command Line Tools"
    install_clt_update
    have="$(swift_version)"
    ver_ge "$have" "$MIN_SWIFT" || { echo "!! still Swift $have after the update" >&2; exit 1; }
fi

python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null || {
    echo "!! python3 3.8+ is missing; it ships with the Command Line Tools: xcode-select --install" >&2
    exit 1
}
echo "==> macOS $macos, Swift $have: ready"
