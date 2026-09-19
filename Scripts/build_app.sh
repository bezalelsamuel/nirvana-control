#!/bin/bash
# Builds Nirvana Control (app + widget) from project.yml, installs it to
# /Applications and restarts it.
#
#   Scripts/build_app.sh
#
# Needs XcodeGen (`brew install xcodegen`) and an Apple ID signed into Xcode
# for the team in project.yml.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="BoatMenuBar"          # Xcode target/scheme
APP_NAME="Nirvana Control"    # the built app (PRODUCT_NAME)
BUNDLE_ID="com.local.boatmenubar"
INSTALLED="/Applications/$APP_NAME.app"

cd "$ROOT_DIR"
xcodegen generate --quiet
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration Release -destination "platform=macOS,arch=arm64" \
    -allowProvisioningUpdates -quiet build

BUILT="$(xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration Release \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/$APP_NAME.app"

# Quit normally rather than kill: the app hangs up its RFCOMM channel on the
# way out, and a killed one leaves the earbuds refusing new sessions.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
for _ in 1 2 3 4 5; do
    pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null || break
    sleep 1
done

# macOS keeps the previous widget process alive across a reinstall and keeps
# drawing the old widget; stop it and restart the widget host.
pkill -f "BoatWidget.appex/Contents/MacOS/BoatWidget" || true

rm -rf "$INSTALLED"
cp -R "$BUILT" "$INSTALLED"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED"
killall chronod 2>/dev/null || true

open "$INSTALLED"
echo "Installed $INSTALLED (build $(plutil -extract CFBundleVersion raw "$INSTALLED/Contents/Info.plist"))"
