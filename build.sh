#!/bin/zsh
# Builds SessionHub.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="build/SessionHub.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SessionHub "$APP/Contents/MacOS/SessionHub"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/SessionHub.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/SessionHub.app"
