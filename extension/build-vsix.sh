#!/bin/bash
# A vsix is a zip with a manifest, so packing it by hand needs no npm, no network, and is byte-stable.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: build-vsix.sh <out.vsix>}"
VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$HERE/package.json")"
STAGE="$(mktemp -d -t aivsix)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/extension"
cp "$HERE/package.json" "$HERE/extension.js" "$STAGE/extension/"
cat > "$STAGE/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension=".json" ContentType="application/json"/><Default Extension=".js" ContentType="application/javascript"/><Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
XML
cat > "$STAGE/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="ide-focus" Version="$VERSION" Publisher="agentisland"/>
    <DisplayName>AgentIsland terminal focus</DisplayName>
    <Description xml:space="preserve">Lets AgentIsland bring the integrated terminal an agent runs in to the front.</Description>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.70.0"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui"/>
    </Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets>
</PackageManifest>
XML
# Fixed timestamps and order, so a rebuild of unchanged sources is byte-identical.
find "$STAGE" -exec touch -t 202601010000 {} +
rm -f "$OUT"; mkdir -p "$(dirname "$OUT")"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
(cd "$STAGE" && zip -qX "$OUT_ABS" "[Content_Types].xml" extension.vsixmanifest \
    extension/package.json extension/extension.js)
echo "$OUT_ABS"
