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
ln -s Ghost "$APP/Contents/MacOS/Ghost Watchdog"   # names the watchdog process

# Sign with a stable self-signed identity (see sign.sh) so the Screen Recording
# grant survives rebuilds; fall back to ad-hoc if that can't be set up.
if ! ./sign.sh "$APP"; then
  echo "warning: stable signing failed, signing ad-hoc (Screen Recording must be granted again)"
  codesign --force --identifier com.yangli.ghost --sign - "$APP"
fi
DEST=/Applications/Ghost.app
req() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p'; }
NEW_REQ=$(req "$APP")
OLD_REQ=$(req "$DEST" || true)
pkill -x "Ghost Watchdog" 2>/dev/null || true   # first, so it doesn't react to Ghost quitting
pkill -x Ghost 2>/dev/null || true
# A grant recorded for another signature would show as on but not work. Clear
# it only when the signature really changed (first stable build, or ad-hoc).
if [ "$NEW_REQ" != "$OLD_REQ" ]; then
  tccutil reset ScreenCapture com.yangli.ghost >/dev/null 2>&1 || true
  GRANT=1
fi

# Install, replacing the old copy, so /Applications never runs a stale build.
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "Built $APP and installed to $DEST"
echo "Run:  open $DEST"
if [ -n "${GRANT:-}" ]; then
  echo "Then: System Settings > Privacy & Security > Screen Recording → turn on Ghost → relaunch."
else
  echo "Same signature as the installed copy: the Screen Recording grant is kept."
fi
echo "Debug: run $DEST/Contents/MacOS/Ghost from a terminal to see log output."
