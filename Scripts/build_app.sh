#!/bin/bash
# Builds the SPM executable and wraps it into a proper .app bundle so macOS
# treats it as a GUI app: shows the Bluetooth permission prompt with our
# Info.plist description, hides the Dock icon (LSUIElement), and can be
# double-clicked from Finder.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BoatMenuBar"
BUILD_CONFIG="release"

cd "$ROOT_DIR"
swift build -c "$BUILD_CONFIG"

BIN_PATH="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/$APP_NAME"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Ad-hoc sign so macOS assigns a stable identity for Bluetooth/TCC prompts.
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
echo "Run with: open \"$APP_BUNDLE\""
