#!/bin/zsh
# Makes AlbumscapeLock-mac.dmg: the installer window with a drag-to-Applications layout and our own background.
# Needs the app built first (./build-app.sh). Finder is scripted to lay the window out, so macOS may ask once to allow
# the terminal to control Finder.
set -e
cd "$(dirname "$0")"
NAME="Albumscape Lock"
OUT=AlbumscapeLock-mac.dmg
STAGE=$(mktemp -d)
RW="$STAGE/rw.dmg"
swift tools/make-dmg-background.swift "$STAGE/background.png" >/dev/null

mkdir -p "$STAGE/src/.background"
# ad-hoc signed, so the maker's developer certificate isn't inside the download
cp -R AlbumscapeLock.app "$STAGE/src/"
codesign --force --sign - "$STAGE/src/AlbumscapeLock.app" >/dev/null 2>&1
cp "$STAGE/background.png" "$STAGE/src/.background/background.png"
ln -s /Applications "$STAGE/src/Applications"
cp Resources/AppIcon.icns "$STAGE/src/.VolumeIcon.icns"

hdiutil create -srcfolder "$STAGE/src" -volname "$NAME" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
DEVICE=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | grep -E '^/dev/' | head -1 | awk '{print $1}')
sleep 2
SetFile -a C "/Volumes/$NAME" 2>/dev/null || true  # use the volume icon

osascript <<OSA
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set label position of opts to bottom
    set background picture of opts to file ".background:background.png"
    set position of item "AlbumscapeLock.app" of container window to {170, 168}
    set position of item "Applications" of container window to {490, 168}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA

sync
hdiutil detach "$DEVICE" >/dev/null
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -rf "$STAGE"
echo "Made $PWD/$OUT"
