#!/bin/bash
# Builds, signs, notarizes and packages QuickZip for distribution outside
# the Mac App Store (see docs/DISTRIBUTION.md).
#
#   TEAM_ID=ABCDE12345 NOTARY_PROFILE=quickzip Scripts/release.sh
#
# TEAM_ID         your Apple Developer team, with a "Developer ID Application"
#                 certificate in the login keychain
# NOTARY_PROFILE  a keychain profile made once with:
#                   xcrun notarytool store-credentials quickzip \
#                     --apple-id you@example.com --team-id ABCDE12345
#
# Output: Distribution/out/QuickZip-<version>.dmg, signed, notarized and stapled.
set -euo pipefail

: "${TEAM_ID:?set TEAM_ID to your Apple Developer team ID}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

cd "$(dirname "$0")/.."
OUT=Distribution/out
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Archiving"
xcodebuild archive \
    -project QuickZip.xcodeproj -scheme QuickZip -configuration Release \
    -archivePath "$OUT/QuickZip.xcarchive" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    | tail -n 5

echo "==> Exporting (Developer ID)"
cp Distribution/ExportOptions.plist "$OUT/ExportOptions.plist"
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$OUT/ExportOptions.plist"
/usr/libexec/PlistBuddy -c "Set :signingStyle manual" "$OUT/ExportOptions.plist"
xcodebuild -exportArchive \
    -archivePath "$OUT/QuickZip.xcarchive" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" \
    | tail -n 5

APP="$OUT/export/QuickZip.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$OUT/QuickZip-$VERSION.dmg"

echo "==> Checking the signature and entitlements"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
    || { echo "The app is not sandboxed"; exit 1; }
codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=0x10000(runtime)" \
    || { echo "The hardened runtime is not enabled"; exit 1; }

echo "==> Checking the command-line tool"
TOOL="$APP/Contents/Helpers/quickzip"
codesign --verify --strict --verbose=2 "$TOOL"
codesign -d --verbose=2 "$TOOL" 2>&1 | grep -q "flags=0x10000(runtime)" \
    || { echo "The command-line tool does not have the hardened runtime"; exit 1; }
# The tool runs from Terminal on the user's own files, so it must not be sandboxed.
if codesign -d --entitlements - "$TOOL" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
    echo "The command-line tool is sandboxed, so it could not read the user's files"; exit 1
fi
"$TOOL" --version

echo "==> Building the disk image"
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "QuickZip" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "==> Notarizing (this waits for Apple, usually a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo
echo "Done: $DMG"
shasum -a 256 "$DMG"
