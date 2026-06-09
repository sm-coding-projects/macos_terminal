#!/bin/sh
# Wraps the SwiftPM release binary into a minimal .app bundle.
# The bundle is UNSIGNED — see RELEASE_CHECKLIST.md for codesigning with
# the sandbox/hardened-runtime entitlements in Resources/.
set -eu

cd "$(dirname "$0")/.."

BINARY=".build/release/SecureSSHTerminal"
APP_DIR="build/SecureSSH Terminal.app"

if [ ! -x "$BINARY" ]; then
    echo "error: release binary missing — run 'make release' first" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/SecureSSHTerminal"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "Created: $APP_DIR"
echo "Next: sign it (see RELEASE_CHECKLIST.md):"
echo "  codesign --force --options runtime \\"
echo "    --entitlements Resources/SecureSSHTerminal.entitlements \\"
echo "    --sign \"Developer ID Application: <YOUR TEAM>\" \"$APP_DIR\""
