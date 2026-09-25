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

# Command Line Tools 27 ships a macOS 27 SDK that redeclares SwiftUI's @State as a macro, but the
# plugin backing it lives only inside Xcode — so with CLT alone every @State fails to compile, and
# a warm .build hides it until the first real recompile. Probe, and fall back to the newest SDK
# that still declares the plain property wrapper. Full Xcode makes the probe pass and changes nothing.
probe="$(mktemp -t aiprobe)".swift
printf 'import SwiftUI\nstruct _P: View { @State var n = 0\n  var body: some View { Text("\\(n)") } }\n' > "$probe"
if ! swiftc -typecheck "$probe" >/dev/null 2>&1; then
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -rV); do
    if swiftc -typecheck -sdk "$sdk" "$probe" >/dev/null 2>&1; then export SDKROOT="$sdk"; break; fi
  done
  [ -n "${SDKROOT:-}" ] || { echo "!! no installed SDK compiles SwiftUI @State — install Xcode"; rm -f "$probe"; exit 1; }
  echo "==> using SDK $(basename "$SDKROOT") (the default SDK's @State needs an Xcode-only plugin)"
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
