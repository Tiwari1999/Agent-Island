#!/bin/bash
# Build a disk image people can download. Works today with an ad-hoc signature; when a Developer
# ID exists, scripts/make-app.sh picks it up on its own and scripts/notarize.sh finishes the job.
#
#   scripts/make-dmg.sh            -> dist/AgentIsland-<version>.dmg
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$REPO/VERSION")"
DIST="$REPO/dist"
STAGE="$(mktemp -d)"
DMG="$DIST/AgentIsland-$VERSION.dmg"

"$REPO/scripts/make-app.sh" "$STAGE/AgentIsland.app"

# The drag-to-install convention. Without the symlink people copy the app into the disk image
# itself, run it from there, and wonder why it disappears when they eject.
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<TXT
AgentIsland $VERSION

1. Drag AgentIsland to Applications.
2. RIGHT-CLICK it and choose Open, then Open again.

Step 2 is needed because this build is not notarized by Apple yet — double-clicking
gives "cannot be opened because the developer cannot be verified". Right-click > Open
is macOS's own way of saying you trust it, and it is only needed the first time.

On first launch the app asks to install its hooks. Nothing is read or sent anywhere
off this machine: it watches the transcripts your agents already write to disk.

Source and issues: https://github.com/Tiwari1999/Agent-Island
TXT

mkdir -p "$DIST"; rm -f "$DMG"
echo "==> packing $DMG"
hdiutil create -volname "AgentIsland $VERSION" -srcfolder "$STAGE" \
               -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo
echo "  $DMG"
echo "  $(du -h "$DMG" | cut -f1)"
if codesign -dv "$DIST" 2>&1 | grep -q "adhoc" ||
   ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  echo
  echo "  NOT NOTARIZED. Gatekeeper will refuse a double-click; the Read me tells people to"
  echo "  right-click > Open. To ship a build that just opens, see docs/RELEASE.md."
fi
