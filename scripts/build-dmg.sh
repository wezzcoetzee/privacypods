#!/bin/zsh
# Builds a Release PrivacyPods.app and packages it as dist/PrivacyPods-<version>.dmg with an Applications shortcut.
# Ad-hoc signed: TCC grants (Motion, Screen Recording, Input Monitoring) survive rebuilds as long as the bundle id is unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild -project PrivacyPods.xcodeproj -scheme PrivacyPods -configuration Release -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build | grep -E "error|BUILD"

APP=build/DerivedData/Build/Products/Release/PrivacyPods.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=build/dmg
DMG=dist/PrivacyPods-$VERSION.dmg

rm -rf "$STAGE" && mkdir -p "$STAGE" dist
ditto "$APP" "$STAGE/PrivacyPods.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "PrivacyPods" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
