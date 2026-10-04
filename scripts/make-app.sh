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
# Sparkle's public key lives only in packaging/sparkle-public-ed-key. While it holds the
# placeholder the app still runs, with its updater off (Updater.swift); env overrides for tests.
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$(cat "$REPO/packaging/sparkle-public-ed-key")}"

# The sources use a ViewState alias because CLT 27's @State macro needs an Xcode-only plugin.
# Probe the same alias so any other SDK breakage still falls back to the newest SDK that builds.
probe="$(mktemp -t aiprobe)".swift
printf 'import SwiftUI\ntypealias ViewState = SwiftUI.State\nstruct _P: View { @ViewState var n = 0\n  var body: some View { Text("\\(n)") } }\n' > "$probe"
if ! probe_err="$(swiftc -typecheck "$probe" 2>&1)"; then
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -rV); do
    if swiftc -typecheck -sdk "$sdk" "$probe" >/dev/null 2>&1; then export SDKROOT="$sdk"; break; fi
  done
  # Show the compiler's own words: a guessed cause once sent someone after Xcode when the real
  # fault was a half-upgraded Command Line Tools install.
  [ -n "${SDKROOT:-}" ] || { echo "!! no installed SDK compiles SwiftUI. The compiler said:"
    echo "$probe_err" | head -15
    echo "!! try updating Command Line Tools: xcode-select --install"; rm -f "$probe"; exit 1; }
  echo "==> using SDK $(basename "$SDKROOT") (the default SDK does not build SwiftUI)"
fi
rm -f "$probe"

echo "==> building $VERSION"
# Homebrew passes --disable-sandbox: SwiftPM's own sandbox cannot start inside brew's.
swift build -c release --package-path "$REPO" ${AGENTISLAND_SWIFT_FLAGS:-}

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$REPO/.build/release/AgentIsland" "$APP/Contents/MacOS/AgentIsland"
# The binary's rpath (Package.swift) points here. -R keeps the framework's Versions symlinks.
mkdir -p "$APP/Contents/Frameworks"
cp -R "$REPO/.build/release/Sparkle.framework" "$APP/Contents/Frameworks/"
# Scripts the app runs at runtime must live in the bundle: an installed app cannot find the
# repo it was built from, so SSH monitoring and in-app hook setup break without these.
mkdir -p "$APP/Contents/Resources"
cp "$REPO/hooks/remote-probe.py" "$APP/Contents/Resources/remote-probe.py"
cp "$REPO/scripts/install-hooks.py" "$APP/Contents/Resources/install-hooks.py"
# The Homebrew cask's uninstall runs this from the bundle; a brew user has no checkout.
cp "$REPO/scripts/uninstall-hooks.py" "$APP/Contents/Resources/uninstall-hooks.py"
# The hooks themselves, or the app's own "install hooks" registers paths that do not exist —
# which is exactly what a download-only user got: fourteen entries pointing at nothing.
mkdir -p "$APP/Contents/Resources/hooks"
cp "$REPO"/hooks/agentisland-* "$APP/Contents/Resources/hooks/"
chmod +x "$APP/Contents/Resources/hooks/"*
# The VS Code / Cursor extension that focuses the exact integrated terminal; install-hooks.py installs it.
"$REPO/extension/build-vsix.sh" "$REPO/.build/agentisland-ide-focus.vsix" >/dev/null
cp "$REPO/.build/agentisland-ide-focus.vsix" "$APP/Contents/Resources/agentisland-ide-focus.vsix"
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
  <key>SUFeedURL</key><string>https://agentisland.in/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
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
  SIGN=(--force --options runtime --timestamp --sign "$IDENTITY")
else
  SIGN=(--force --sign -)
fi
# Inside-out, in Sparkle's documented order: a nested helper signed after its container breaks
# the container's seal. The Downloader keeps the entitlements Sparkle shipped it with.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${SIGN[@]}" "$FW/XPCServices/Installer.xpc"
codesign "${SIGN[@]}" --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
codesign "${SIGN[@]}" "$FW/Autoupdate"
codesign "${SIGN[@]}" "$FW/Updater.app"
codesign "${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN[@]}" --identifier "$BUNDLE_ID" "$APP"
