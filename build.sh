#!/bin/bash
# Builds SnapMark and assembles a double-clickable .app bundle.
set -e
cd "$(dirname "$0")"

APP_NAME="SnapMark"
APP_BUNDLE="dist/$APP_NAME.app"

echo "Compiling…"
# Weak-link frameworks that only exist in newer SDKs (Apple Intelligence needs
# the macOS 26 SDK, on-device Translation the macOS 15 SDK) so the app still
# launches on older macOS. The matching code is already guarded by
# #if canImport + @available, so nothing breaks when they're absent.
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
WEAK_FLAGS=""
for FW in FoundationModels Translation; do
    if [ -n "$SDK_PATH" ] && [ -d "$SDK_PATH/System/Library/Frameworks/$FW.framework" ]; then
        WEAK_FLAGS="$WEAK_FLAGS -Xlinker -weak_framework -Xlinker $FW"
    fi
done
# shellcheck disable=SC2086
swift build -c release $WEAK_FLAGS

echo "Assembling $APP_BUNDLE…"
rm -rf dist
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.example.snapmark</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Ad-hoc sign so it launches cleanly on the build machine.
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo "Done: $APP_BUNDLE"
echo "Drag it to /Applications, launch it, and press Ctrl+Shift+5."
