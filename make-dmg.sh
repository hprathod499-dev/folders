#!/bin/bash
# Builds Folders.app and packs it into build/Folders.dmg (drag the app onto Applications to install).
# Run: ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "1.0")
STAGE="build/dmg"
DMG="build/Folders-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto build/Folders.app "$STAGE/Folders.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Folders" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
rm -rf "$STAGE"
cp "$DMG" build/Folders.dmg   # fixed name used by the "latest" download link
mkdir -p Download && cp "$DMG" Download/Folders.dmg   # shown at the top of the GitHub page
echo "Made: $DMG ($(du -h "$DMG" | cut -f1))"
