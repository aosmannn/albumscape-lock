#!/bin/zsh
# Builds AlbumscapeLock.app (ad-hoc signed) next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=AlbumscapeLock.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/AlbumscapeLock "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources" && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# the clock's liquid shader (Shaders/Liquid.metal) for SwiftUI's ShaderLibrary.default
AIR=$(mktemp -d)/Liquid.air
xcrun -sdk macosx metal -c Shaders/Liquid.metal -o "$AIR"
xcrun -sdk macosx metallib "$AIR" -o "$APP/Contents/Resources/default.metallib"
# what the Mac says is playing, from any app (loaded into perl by SystemNowPlaying.swift)
clang -dynamiclib -fobjc-arc -framework Foundation -o "$APP/Contents/Resources/mediaremote.dylib" Native/mediaremote.m
codesign --force --sign - "$APP/Contents/Resources/mediaremote.dylib" >/dev/null 2>&1
# A stable identity keeps macOS's privacy permissions (Input Monitoring) across rebuilds; ad-hoc signing changes them every time.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $PWD/$APP"
