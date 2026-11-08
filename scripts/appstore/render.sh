#!/bin/sh
# Renders the Mac App Store screenshots (2880x1800, 16:10) into docs/appstore/.
#
#   scripts/appstore/render.sh                 # renders the UI first with scripts/snapshots.sh
#   scripts/appstore/render.sh <snapshot-dir>  # reuses renders you already have
#
# Needs Google Chrome for the headless render. The slides live in slides.html, one per #hash.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -n "${1:-}" ]; then
  snapshots="$(cd "$1" && pwd)"
else
  snapshots="$work/snapshots"
  "$root/scripts/snapshots.sh" "$snapshots" >/dev/null
fi

cp "$here/slides.html" "$work/"
cp -R "$here/assets" "$work/assets"
mkdir "$work/ui"
cp "$snapshots"/*.png "$work/ui/"
iconutil --convert iconset --output "$work/AppIcon.iconset" "$root/Supporting/AppIcon.icns"
cp "$work/AppIcon.iconset/icon_256x256@2x.png" "$work/assets/icon.png"

out="$root/docs/appstore"
mkdir -p "$out"
index=1
for slide in hero displays lock menu setup status honest; do
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=1440,900 --virtual-time-budget=3000 \
    --screenshot="$out/0$index-$slide.png" "file://$work/slides.html#$slide" >/dev/null 2>&1
  index=$((index + 1))
done
ls "$out"
