#!/bin/bash
# Build AgentIsland.app at a given path. The one place a bundle is assembled, so the disk image
# people download cannot drift from the one ./install.sh puts on the developer's own machine.
#
#   scripts/make-app.sh <destination.app>
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: make-app.sh <destination.app>}"
VERSION="$(cat "$REPO/VERSION" 2>/dev/null || echo 0.0.0)"
BUNDLE_ID="io.github.tiwari1999.agentisland"

# The sources use a ViewState alias because CLT 27's @State macro needs an Xcode-only plugin.
# Probe the same alias so any other SDK breakage still falls back to the newest SDK that builds.
probe="$(mktemp -t aiprobe)".swift
printf 'import SwiftUI\ntypealias ViewState = SwiftUI.State\nstruct _P: View { @ViewState var n = 0\n  var body: some View { Text("\\(n)") } }\n' > "$probe"
if ! swiftc -typecheck "$probe" >/dev/null 2>&1; then
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -rV); do
    if swiftc -typecheck -sdk "$sdk" "$probe" >/dev/null 2>&1; then export SDKROOT="$sdk"; break; fi
  done
  [ -n "${SDKROOT:-}" ] || { echo "!! no installed SDK compiles SwiftUI — update Command Line Tools: xcode-select --install"; rm -f "$probe"; exit 1; }
  echo "==> using SDK $(basename "$SDKROOT") (the default SDK does not build SwiftUI)"
fi
rm -f "$probe"

echo "==> building $VERSION"
swift build -c release --package-path "$REPO"

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$REPO/.build/release/AgentIsland" "$APP/Contents/MacOS/AgentIsland"
# Scripts the app runs at runtime must live in the bundle: an installed app cannot find the
# repo it was built from, so SSH monitoring and in-app hook setup break without these.
mkdir -p "$APP/Contents/Resources"
cp "$REPO/hooks/remote-probe.py" "$APP/Contents/Resources/remote-probe.py"
cp "$REPO/scripts/install-hooks.py" "$APP/Contents/Resources/install-hooks.py"
# The hooks themselves, or the app's own "install hooks" registers paths that do not exist —
# which is exactly what a download-only user got: fourteen entries pointing at nothing.
mkdir -p "$APP/Contents/Resources/hooks"
cp "$REPO"/hooks/agentisland-* "$APP/Contents/Resources/hooks/"
chmod +x "$APP/Contents/Resources/hooks/"*
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AgentIsland</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>AgentIsland</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <!-- Ad-hoc builds are not asked for this, so its absence costs nothing until the day this is
       signed with a Developer ID and hardened — then Apple Events are denied with no error and
       the iTerm/Terminal jump silently stops working. -->
  <key>NSAppleEventsUsageDescription</key><string>AgentIsland asks your terminal to bring the tab an agent is running in to the front.</string>
</dict></plist>
PLIST

# A Developer ID signature when there is one, ad-hoc otherwise. Ad-hoc still runs, but Gatekeeper
# makes the first launch a right-click > Open, and the Accessibility grant is dropped on every
# rebuild because the signature changes with the binary.
# `|| true`: with no Developer ID installed grep exits 1, and under `set -e` that ends the
# build — the unsigned path is the normal one until an Apple account exists, not a failure.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
if [ -n "$IDENTITY" ]; then
  echo "==> signing as $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
