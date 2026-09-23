#!/bin/bash
# Build, install to ~/Applications, register hooks, and launch.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/AgentIsland.app"

echo "==> installing to $APP"
pkill -f "AgentIsland.app/Contents/MacOS/AgentIsland" 2>/dev/null || true
# Wait for the old instance to actually exit: launching while it is still dying makes
# LaunchServices treat the new instance as a duplicate, which exits silently seconds later.
for _ in $(seq 1 25); do pgrep -x AgentIsland >/dev/null || break; sleep 0.2; done
# One place assembles a bundle, so what a stranger downloads cannot drift from what runs here.
"$REPO/scripts/make-app.sh" "$APP"

echo "==> registering hooks"
python3 "$REPO/scripts/install-hooks.py" "$REPO"

echo "==> registering login item"
# Without this the island is gone after a restart, which is the one moment the user is least
# likely to notice it missing. RunAtLoad only, no KeepAlive: Settings has a Quit, and a quit
# launchd undoes two seconds later is a bug.
AGENT="$HOME/Library/LaunchAgents/io.github.tiwari1999.agentisland.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.github.tiwari1999.agentisland</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/AgentIsland</string></array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
# Re-bootstrap so an upgraded path takes effect; the app's own single-instance guard means a
# duplicate start here costs nothing.
launchctl bootout "gui/$UID/io.github.tiwari1999.agentisland" 2>/dev/null || true
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
