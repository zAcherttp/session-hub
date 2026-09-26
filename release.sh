#!/bin/zsh
# Builds a universal (arm64 + x86_64) SessionHub.app and zips it into dist/ for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?usage: ./release.sh <version>}"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SessionHub"
APP="dist/SessionHub.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SessionHub"
sed -e "s/<string>1.0<\/string>/<string>$VERSION<\/string>/" Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" "dist/SessionHub-$VERSION.zip"
echo "dist/SessionHub-$VERSION.zip"
