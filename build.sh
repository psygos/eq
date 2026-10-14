#!/bin/sh
# Builds build/eq.app. One swiftc call, no dependencies, signed with the local Apple Development
# identity so the "System Audio Recording" permission survives rebuilds.
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
APP=build/eq.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -wmo -swift-version 5 -target arm64-apple-macos15.0 -enforce-exclusivity=unchecked \
  Sources/*.swift -o "$APP/Contents/MacOS/eq"
cp Info.plist "$APP/Contents/"
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP" 2>&1 | grep -v 'replacing existing signature' || true
echo "built $APP ($(du -sh "$APP" | cut -f1)), signed: ${IDENTITY:-ad-hoc}"
