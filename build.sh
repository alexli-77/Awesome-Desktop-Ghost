#!/bin/bash
# Build Ghost.app next to this script and install it to /Applications.
# Needs Xcode or Command Line Tools.
set -e
cd "$(dirname "$0")"

APP=Ghost.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"

# App icon: PNG → .icns (iconutil is macOS-only)
ICONSET=$(mktemp -d)/Ghost.iconset
mkdir -p "$ICONSET" "$APP/Contents/Resources"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz assets/icon_1024.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) assets/icon_1024.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Ghost.icns"

swiftc -O \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework ScreenCaptureKit -framework Carbon \
  -o "$APP/Contents/MacOS/Ghost" main.swift

# Ad-hoc sign with a fixed identifier. NOTE: an ad-hoc signature's hash changes
# on every build, so macOS forgets the old Screen Recording grant. Clear the
# stale entry so the next launch asks cleanly instead of silently failing.
codesign --force --identifier com.yangli.ghost --sign - "$APP"
pkill -x Ghost 2>/dev/null || true
tccutil reset ScreenCapture com.yangli.ghost >/dev/null 2>&1 || true

# Install, replacing the old copy, so /Applications never runs a stale build.
DEST=/Applications/Ghost.app
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "Built $APP and installed to $DEST"
echo "Run:  open $DEST"
echo "Then: System Settings > Privacy & Security > Screen Recording → turn on Ghost → relaunch."
echo "Debug: run $DEST/Contents/MacOS/Ghost from a terminal to see log output."
