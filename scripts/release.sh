#!/bin/bash
# Everything a release needs from what VERSION already says — it bumps nothing. Builds the DMG
# (notarized when the Apple credentials exist), signs it for Sparkle, adds the appcast entry and
# fills the Homebrew cask's version and sha256. Publishing stays a human step: see docs/RELEASE.md.
#
#   scripts/release.sh                                  # Sparkle key from the login keychain
#   SPARKLE_PRIVATE_KEY_FILE=/path/key scripts/release.sh
#   SPARKLE_PRIVATE_KEY="$SECRET" scripts/release.sh   # e.g. from a CI secret
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$REPO/VERSION")"
DMG="$REPO/dist/AgentIsland-$VERSION.dmg"
URL="https://github.com/Tiwari1999/Agent-Island/releases/download/v$VERSION/AgentIsland-$VERSION.dmg"
APPCAST="$REPO/packaging/appcast.xml"
CASK="$REPO/packaging/homebrew/Casks/agent-island.rb"
BIN="$REPO/.build/artifacts/sparkle/Sparkle/bin"
PROFILE="${AGENTISLAND_NOTARY_PROFILE:-agentisland}"

# A build shipped without the real public key can never be auto-updated again, so refuse it.
KEY="${SPARKLE_PUBLIC_ED_KEY:-$(cat "$REPO/packaging/sparkle-public-ed-key")}"
[ "$(printf %s "$KEY" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" = 32 ] || {
  echo "!! packaging/sparkle-public-ed-key still holds the placeholder. docs/RELEASE.md, step 'Sparkle key'."
  exit 1; }

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" &&
   xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  "$REPO/scripts/notarize.sh"          # rebuilds the DMG itself, then submits and staples
else
  "$REPO/scripts/make-dmg.sh"
  echo
  echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "  !! SHIPPING UNNOTARIZED: no Developer ID certificate, or no notary profile"
  echo "  !! '$PROFILE'. Users must right-click > Open. docs/RELEASE.md has the fix."
  echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo
fi

echo "==> signing for Sparkle"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  SIG="$(printf %s "$SPARKLE_PRIVATE_KEY" | "$BIN/sign_update" --ed-key-file - "$DMG")"
elif [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
  SIG="$("$BIN/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$DMG")"
else
  SIG="$("$BIN/sign_update" "$DMG")"
fi
ED="$(printf %s "$SIG" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LEN="$(printf %s "$SIG" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
[ -n "$ED" ] && [ -n "$LEN" ] || { echo "!! sign_update said: $SIG"; exit 1; }

echo "==> appcast entry for $VERSION"
python3 - "$APPCAST" "$VERSION" "$URL" "$ED" "$LEN" <<'PY'
import os, sys, email.utils, xml.etree.ElementTree as ET
path, version, url, sig, length = sys.argv[1:]
SP = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SP)
if os.path.exists(path):
    rss = ET.parse(path).getroot()
else:
    rss = ET.Element("rss", {"version": "2.0"})
    ET.SubElement(ET.SubElement(rss, "channel"), "title").text = "AgentIsland"
channel = rss.find("channel")
# Re-running a release replaces its entry rather than listing the version twice.
for old in channel.findall("item"):
    if old.findtext(f"{{{SP}}}version") == version:
        channel.remove(old)
item = ET.Element("item")
ET.SubElement(item, "title").text = f"AgentIsland {version}"
ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
ET.SubElement(item, f"{{{SP}}}version").text = version
ET.SubElement(item, f"{{{SP}}}shortVersionString").text = version
ET.SubElement(item, f"{{{SP}}}minimumSystemVersion").text = "14.0"
ET.SubElement(item, "enclosure", {"url": url, "length": length,
              "type": "application/octet-stream", f"{{{SP}}}edSignature": sig})
channel.insert(list(channel).index(channel.find("title")) + 1, item)
ET.indent(rss)
ET.ElementTree(rss).write(path, encoding="utf-8", xml_declaration=True)
PY

echo "==> cask $VERSION"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"

echo
echo "  $DMG"
echo "  sha256 $SHA"
echo "  Not done for you: tag v$VERSION, attach the DMG to the GitHub release, upload"
echo "  packaging/appcast.xml to https://agentisland.in/appcast.xml, copy the cask to the tap."
