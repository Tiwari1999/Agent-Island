#!/bin/bash
# Build, install to ~/Applications, register hooks, and launch.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/AgentIsland.app"

echo "==> building"
swift build -c release --package-path "$REPO"

echo "==> installing to $APP"
pkill -f "AgentIsland.app/Contents/MacOS/AgentIsland" 2>/dev/null || true
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$REPO/.build/release/AgentIsland" "$APP/Contents/MacOS/AgentIsland"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AgentIsland</string>
  <key>CFBundleIdentifier</key><string>sh.emergent.agentisland</string>
  <key>CFBundleExecutable</key><string>AgentIsland</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier sh.emergent.agentisland "$APP"

echo "==> registering hooks"
python3 "$REPO/scripts/install-hooks.py" "$REPO"

echo "==> launching"
open "$APP"
echo "done — hover the notch"
