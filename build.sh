#!/bin/bash
# Builds SnapMark, runs the dev checks, and assembles a double-clickable .app.
#
# Dev checks (all logged):
#   1. tools/audit.py  - static audit (availability guards, balance, warnings)
#   2. swift build      - full compile
#   3. swift test       - unit tests (skip with SKIP_TESTS=1)
#
# Logs land in dist/logs/ with timestamps. If anything fails, send the newest
# dist/logs/build-*.log (or test-*.log) to Bell — it contains the environment
# details and the full compiler output needed to fix it.
set -u
cd "$(dirname "$0")"

APP_NAME="SnapMark"
APP_BUNDLE="dist/$APP_NAME.app"
LOGDIR="dist/logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_LOG="$LOGDIR/build-$STAMP.log"
TEST_LOG="$LOGDIR/test-$STAMP.log"
mkdir -p "$LOGDIR"

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; }

{
echo "=== SnapMark build $STAMP ==="
echo "--- environment ---"
sw_vers 2>/dev/null || echo "(sw_vers unavailable)"
xcodebuild -version 2>/dev/null || echo "(xcodebuild unavailable)"
swift --version 2>&1 | head -2
echo "SDK: $(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo unavailable)"
echo "git: $(git rev-parse --short HEAD 2>/dev/null || echo unavailable)"
echo ""
} | tee "$BUILD_LOG"

echo "▶︎ 1/3 static audit…"
if python3 tools/audit.py 2>&1 | tee -a "$BUILD_LOG"; then
    pass "static audit"
else
    fail "static audit — see $BUILD_LOG"
    echo ""
    echo "Fix the errors above, then re-run ./build.sh."
    exit 1
fi

echo "▶︎ 2/3 compiling…"
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
if swift build -c release $WEAK_FLAGS 2>&1 | tee -a "$BUILD_LOG"; then
    pass "compile"
else
    fail "compile — extracting errors"
    grep -E "error:" "$BUILD_LOG" | head -40 | tee "$LOGDIR/errors-$STAMP.log"
    echo ""
    echo "Build failed. Send this file to Bell: $BUILD_LOG"
    exit 1
fi

if [ "${SKIP_TESTS:-0}" = "1" ]; then
    echo "▶︎ 3/3 tests skipped (SKIP_TESTS=1)"
else
    echo "▶︎ 3/3 unit tests…"
    echo "=== SnapMark tests $STAMP ===" > "$TEST_LOG"
    set -o pipefail
    if swift test 2>&1 | tee -a "$TEST_LOG" | tee -a "$BUILD_LOG" > /dev/null; then
        set +o pipefail
        pass "unit tests"
    else
        set +o pipefail
        fail "unit tests — see $TEST_LOG"
        grep -E "error:|failed" "$TEST_LOG" | head -30
        echo ""
        echo "Tests failed. Send this file to Bell: $TEST_LOG"
        exit 1
    fi
fi

echo "▶︎ assembling $APP_BUNDLE…"
rm -rf dist/"$APP_NAME.app"
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
echo "Logs: $BUILD_LOG"
[ "${SKIP_TESTS:-0}" = "1" ] || echo "      $TEST_LOG"
echo "Drag the app to /Applications, launch it, and press Ctrl+Shift+5."
