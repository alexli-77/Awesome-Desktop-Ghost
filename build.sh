#!/bin/bash
# Build Ghost.app next to this script. Needs Xcode or Command Line Tools.
set -e
cd "$(dirname "$0")"

APP=Ghost.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"

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

echo "Built $APP"
echo "Run:  open $APP"
echo "Then: System Settings > Privacy & Security > Screen Recording → turn on Ghost → relaunch."
echo "Debug: run $APP/Contents/MacOS/Ghost from a terminal to see log output."
