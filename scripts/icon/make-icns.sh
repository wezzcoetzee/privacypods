#!/bin/zsh
# Renders the app icon (half-blur-pods variant) and writes Supporting/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/../.."
TMP=build/icon; SET=$TMP/AppIcon.iconset
mkdir -p "$SET"
swiftc -O -o "$TMP/render" scripts/icon/render.swift 2>/dev/null
"$TMP/render" half-blur-pods "$TMP/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Supporting/AppIcon.icns
echo "wrote Supporting/AppIcon.icns"
