#!/bin/zsh
# Builds SessionHub.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
# SwiftPM records the deployment target (14.0) as the linked SDK version; macOS then renders
# system controls in their legacy style. Stamp the real SDK so the toolbar gets Liquid Glass.
stamp_sdk() {
  vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace -output "$1" "$1" 2>/dev/null
}
APP="build/SessionHub.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SessionHub "$APP/Contents/MacOS/SessionHub"
stamp_sdk "$APP/Contents/MacOS/SessionHub"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Schema/claude-storage-baseline.json "$APP/Contents/Resources/"
# Compile the Icon Composer document (Icon/AppIcon.icon) into Assets.car (Liquid Glass) + AppIcon.icns (older macOS).
ICON_OUT="$(mktemp -d)"
xcrun actool Icon/AppIcon.icon --compile "$ICON_OUT" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null
cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/SessionHub.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/SessionHub.app"
