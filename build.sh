#!/bin/zsh
# Builds SessionHub.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="build/SessionHub.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SessionHub "$APP/Contents/MacOS/SessionHub"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Session Hub</string>
  <key>CFBundleDisplayName</key><string>Session Hub</string>
  <key>CFBundleIdentifier</key><string>local.phat.sessionhub</string>
  <key>CFBundleExecutable</key><string>SessionHub</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Session Hub opens Claude Code sessions in iTerm2.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/SessionHub.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/SessionHub.app"
