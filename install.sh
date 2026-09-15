#!/bin/bash
# Build, install to ~/Applications, register hooks, and launch.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/AgentIsland.app"

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

echo "==> building"
swift build -c release --package-path "$REPO"

echo "==> installing to $APP"
pkill -f "AgentIsland.app/Contents/MacOS/AgentIsland" 2>/dev/null || true
# Wait for the old instance to actually exit: launching while it is still dying makes
# LaunchServices treat the new instance as a duplicate, which exits silently seconds later.
for _ in $(seq 1 25); do pgrep -x AgentIsland >/dev/null || break; sleep 0.2; done
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$REPO/.build/release/AgentIsland" "$APP/Contents/MacOS/AgentIsland"
# Scripts the app runs at runtime must live in the bundle: an installed app cannot find the
# repo it was built from, so SSH monitoring and in-app hook setup break without these.
mkdir -p "$APP/Contents/Resources"
cp "$REPO/hooks/remote-probe.py" "$APP/Contents/Resources/remote-probe.py"
cp "$REPO/scripts/install-hooks.py" "$APP/Contents/Resources/install-hooks.py"
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

echo "==> registering login item"
# Without this the island is gone after a restart, which is the one moment the user is least
# likely to notice it missing. RunAtLoad only, no KeepAlive: Settings has a Quit, and a quit
# launchd undoes two seconds later is a bug.
AGENT="$HOME/Library/LaunchAgents/sh.emergent.agentisland.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>sh.emergent.agentisland</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/AgentIsland</string></array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
# Re-bootstrap so an upgraded path takes effect; the app's own single-instance guard means a
# duplicate start here costs nothing.
launchctl bootout "gui/$UID/sh.emergent.agentisland" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$AGENT" 2>/dev/null || true

echo "==> launching"
# rm -rf on the bundle leaves LaunchServices holding a stale registration, which answers -600
# and starts nothing. Re-register, then retry and verify: a silent failure here leaves no
# island running, and every hook falls straight through to the terminal.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREG" ] && "$LSREG" -f "$APP" 2>/dev/null || true
for _ in $(seq 1 8); do
    pgrep -x AgentIsland >/dev/null && break
    open "$APP" 2>/dev/null || true
    sleep 1
done
if pgrep -x AgentIsland >/dev/null; then
    echo "done — hover the notch"
else
    echo "! AgentIsland did not start. Open $APP from Finder, then re-run this script." >&2
    exit 1
fi
