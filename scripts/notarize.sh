#!/bin/bash
# Sign, notarize and staple a disk image so it opens on a double-click.
#
# Unused until there is an Apple Developer Program membership — it exits with instructions
# rather than half-doing the job, because a half-notarized DMG fails on the user's machine
# instead of on yours.
#
#   scripts/notarize.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$REPO/VERSION")"
DMG="$REPO/dist/AgentIsland-$VERSION.dmg"
PROFILE="${AGENTISLAND_NOTARY_PROFILE:-agentisland}"

fail() { echo; echo "  $1"; echo; exit 1; }

security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" || fail \
"No Developer ID Application certificate in this keychain.
  It comes with an Apple Developer Program membership (\$99/yr):
    1. developer.apple.com > Certificates > + > Developer ID Application
    2. download and double-click the .cer
  Then run this again. docs/RELEASE.md has the whole path."

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || fail \
"No stored notary credentials under the profile '$PROFILE'. Create them once:
    xcrun notarytool store-credentials $PROFILE \\
      --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
  The password is an app-specific one from appleid.apple.com, not your Apple ID password."

# Rebuilt rather than reused: make-app.sh signs with the Developer ID once one exists, and a DMG
# built before the certificate arrived still holds the ad-hoc signature inside it.
"$REPO/scripts/make-dmg.sh"

echo "==> submitting (Apple usually answers in a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# Stapling writes the ticket into the DMG so it opens on a machine that is offline.
echo "==> stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "  $DMG is notarized. A double-click opens it with no warning."
echo "  Check it the way a stranger would, on a Mac that has never seen this build:"
echo "    spctl -a -t open --context context:primary-signature -vv \"$DMG\""
