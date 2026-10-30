#!/bin/bash
# Build Lecture Reflector (Release) and install it into /Applications.
# Usage: ./install.sh
set -e
cd "$(dirname "$0")"
APP_NAME="LectureReflector"
BUILT="$HOME/Library/Caches/LectureReflectorBuild/Build/Products/Release/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

./build.sh build Release

if pgrep -x "$APP_NAME" > /dev/null || pgrep -f "$DEST/Contents/MacOS" > /dev/null; then
    echo "Quitting the running copy of $APP_NAME..."
    osascript -e 'tell application id "com.kevinmiller.lecture_reflector" to quit' 2>/dev/null || true
    sleep 2
fi

OLD_VERSION=$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "none")
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

NEW_VERSION=$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString)
NEW_BUILD=$(defaults read "$DEST/Contents/Info" CFBundleVersion)
EXEC=$(defaults read "$DEST/Contents/Info" CFBundleExecutable)
if cmp -s "$BUILT/Contents/MacOS/$EXEC" "$DEST/Contents/MacOS/$EXEC"; then
    MATCH="identical to the latest build"
else
    MATCH="DIFFERENT from the latest build"
fi
codesign --verify --deep --strict "$DEST" && SIGNED="signature valid" || SIGNED="signature INVALID"

echo "Installed $DEST"
echo "Version: $OLD_VERSION -> $NEW_VERSION (build $NEW_BUILD)"
echo "Executable: $MATCH; $SIGNED"
echo "Built: $(stat -f '%Sm' "$DEST/Contents/MacOS/$EXEC")"
