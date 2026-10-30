#!/bin/bash
# Build a Lecture Reflector release that opens on any Mac without a warning:
# Release build signed with Developer ID, packed in a DMG, notarized by
# Apple, and stapled.
#
#   ./release.sh
#
# Needs, once:
#   - a "Developer ID Application" certificate in your keychain
#     (Xcode → Settings → Accounts → Manage Certificates → + )
#   - notarization credentials saved in the keychain; the script offers to
#     save them the first time (Apple ID, team ID, and an app-specific
#     password from account.apple.com → Sign-In and Security)
#
# Set NOTARY_PROFILE to use credentials already saved under another name.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="LectureReflector"
TEAM_ID="YCTW9YH58J"
NOTARY_PROFILE="${NOTARY_PROFILE:-LectureReflector-notary}"
DERIVED_DATA_PATH="$HOME/Library/Caches/LectureReflectorBuild-DeveloperID"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME.app"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

step() { echo; echo "==> $1"; }
fail() { echo; echo "ERROR: $1" >&2; exit 1; }

# 1. Certificate
step "Checking for a Developer ID Application certificate"
IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "$TEAM_ID" | head -1 \
    | sed -E 's/.*"(.*)"/\1/' || true)
[ -n "$IDENTITY" ] || fail "No \"Developer ID Application\" certificate for team $TEAM_ID in your keychain.
In Xcode: Settings → Accounts → select your team → Manage Certificates → + → Developer ID Application. Then run this again."
echo "Using: $IDENTITY"

# 2. Notarization credentials
step "Checking notarization credentials (keychain profile \"$NOTARY_PROFILE\")"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "No saved credentials under \"$NOTARY_PROFILE\". Saving them now."
    echo "You'll need your Apple ID email and an app-specific password"
    echo "(make one at account.apple.com → Sign-In and Security → App-Specific Passwords)."
    xcrun notarytool store-credentials "$NOTARY_PROFILE" --team-id "$TEAM_ID"
fi

# 3. Build, signed with Developer ID
step "Building Release with Developer ID signing"
rm -rf "$DERIVED_DATA_PATH/Build/Products/Release"
mkdir -p "$PROJECT_DIR/build-output"
xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build > "$PROJECT_DIR/build-output/release-build.log" 2>&1 || true
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$PROJECT_DIR/build-output/release-build.log" || true
[ -d "$APP_PATH" ] || fail "The build failed. Full log: build-output/release-build.log"

codesign --verify --deep --strict "$APP_PATH" || fail "The app's signature didn't verify."
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
echo "Built version $VERSION ($BUILD)"

# 4. DMG
step "Making the disk image"
mkdir -p "$PROJECT_DIR/releases"
DMG_PATH="$PROJECT_DIR/releases/LectureReflector-$VERSION.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "Lecture Reflector $VERSION" -srcfolder "$STAGING" \
    -ov -format UDZO -imagekey zlib-level=9 "$DMG_PATH" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG_PATH"

# 5. Notarize and staple
step "Sending to Apple for notarization (usually a few minutes)"
if ! xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait \
        --output-format plist > "$STAGING/notary.plist"; then
    cat "$STAGING/notary.plist" 2>/dev/null || true
    fail "Notarization submission failed."
fi
STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$STAGING/notary.plist")
SUBMISSION=$(/usr/libexec/PlistBuddy -c "Print :id" "$STAGING/notary.plist")
if [ "$STATUS" != "Accepted" ]; then
    mkdir -p "$PROJECT_DIR/build-output"
    xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" \
        "$PROJECT_DIR/build-output/notary-log.json" || true
    fail "Apple returned \"$STATUS\". Details: build-output/notary-log.json"
fi

xcrun stapler staple "$DMG_PATH"

# 6. Check it the way Gatekeeper will
step "Checking with Gatekeeper"
spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"

echo
echo "Done: $DMG_PATH"
echo "Send this file; it opens on any Mac running macOS 14 or later."
