#!/bin/zsh
# Builds a universal (arm64 + x86_64) SessionHub.app and zips it into dist/ for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?usage: ./release.sh <version>}"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SessionHub"
# SwiftPM records the deployment target (14.0) as the linked SDK version; macOS then renders
# system controls in their legacy style. Stamp the real SDK so the toolbar gets Liquid Glass.
stamp_sdk() {
  vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace -output "$1" "$1" 2>/dev/null
}
APP="dist/SessionHub.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SessionHub"
stamp_sdk "$APP/Contents/MacOS/SessionHub"
sed -e "s/<string>1.0<\/string>/<string>$VERSION<\/string>/" Info.plist > "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Schema/claude-storage-baseline.json "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" "dist/SessionHub-$VERSION.zip"
echo "dist/SessionHub-$VERSION.zip"
