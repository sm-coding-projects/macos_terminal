#!/bin/sh
# Builds a universal (arm64 + x86_64) release binary, wraps it into
# SecureSSH Terminal.app, signs it, and packs a drag-to-Applications DMG
# for distribution to testers.
#
# Signing:
#   - Default: ad-hoc signature. Recipients must right-click -> Open the
#     first time (the app is not notarized).
#   - Set SIGN_IDENTITY="Developer ID Application: ..." to sign properly;
#     see RELEASE_CHECKLIST.md for notarization afterwards.
#
# Universal build note: `swift build --arch a --arch b` needs full Xcode,
# so we build each slice via --triple (works with Command Line Tools)
# and merge with lipo.
set -eu

cd "$(dirname "$0")/.."

APP_NAME="SecureSSH Terminal"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
STAGING="build/dmg-staging"
APP_DIR="$STAGING/$APP_NAME.app"
DMG="build/SecureSSH-Terminal-$VERSION.dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> Building arm64 slice"
swift build -c release --triple arm64-apple-macosx

echo "==> Building x86_64 slice"
swift build -c release --triple x86_64-apple-macosx

echo "==> Creating universal binary"
mkdir -p build
lipo -create \
    .build/arm64-apple-macosx/release/SecureSSHTerminal \
    .build/x86_64-apple-macosx/release/SecureSSHTerminal \
    -output build/SecureSSHTerminal-universal
lipo -archs build/SecureSSHTerminal-universal

echo "==> Assembling $APP_NAME.app"
rm -rf "$STAGING" "$DMG"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp build/SecureSSHTerminal-universal "$APP_DIR/Contents/MacOS/SecureSSHTerminal"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

echo "==> Signing (identity: $SIGN_IDENTITY)"
if [ "$SIGN_IDENTITY" = "-" ]; then
    # Ad-hoc: no hardened runtime/entitlements (they require a real identity
    # to be meaningful, and sandbox entitlements break ad-hoc signed apps
    # launched outside an installer-blessed context on some systems).
    codesign --force --deep --sign - "$APP_DIR"
else
    codesign --force --options runtime \
        --entitlements Resources/SecureSSHTerminal.entitlements \
        --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
codesign --verify --strict "$APP_DIR"

echo "==> Staging DMG contents"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/READ ME FIRST.txt" <<'EOF'
SecureSSH Terminal — tester install
===================================

1. Drag "SecureSSH Terminal.app" onto the Applications folder shortcut.
2. FIRST LAUNCH ONLY: macOS will warn that the app is from an
   unidentified developer (this test build is not notarized).

   Right-click (or Control-click) the app in Applications and
   choose "Open", then click "Open" in the dialog.

   On macOS 15+ you may instead need to go to
   System Settings -> Privacy & Security and click "Open Anyway".

3. After that it opens normally.

The app stores SSH passwords only in your macOS Keychain (opt-in),
sends no telemetry, and connects only to the SSH servers you add.
EOF

echo "==> Creating DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
rm -rf "$STAGING" build/SecureSSHTerminal-universal

echo ""
echo "Created: $DMG"
du -h "$DMG" | cut -f1 | sed 's/^/Size: /'
