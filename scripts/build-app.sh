#!/bin/sh
# Builds build/SingleKey.app and build/SingleKey.zip (to copy to your other Mac).
set -e
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
APP=build/SingleKey.app
rm -rf "$APP" build/SingleKey.zip
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SingleKey" "$APP/Contents/MacOS/SingleKey"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# A stable signing identity keeps macOS privacy permissions across rebuilds; an ad-hoc
# signature changes every build, so Accessibility would have to be granted again each time.
IDENTITY="SingleKey Local Signing"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier io.github.gurpreetkaits.singlekey "$APP"
else
    codesign --force --sign - --identifier io.github.gurpreetkaits.singlekey "$APP"
fi
(cd build && ditto -c -k --keepParent SingleKey.app SingleKey.zip)
echo "Built $APP and build/SingleKey.zip"
