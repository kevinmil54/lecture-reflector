#!/bin/bash
# DMG Building Workflow for Lecture Reflector
# Creates a macOS disk image (.dmg) from the Release build

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="LectureReflector"
BUILD_CONFIG="${1:-Release}"
DERIVED_DATA_PATH="$HOME/Library/Caches/LectureReflectorBuild"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$BUILD_CONFIG/$APP_NAME.app"
DMG_OUTPUT_DIR="$PROJECT_DIR/releases"
DMG_FILENAME="$APP_NAME-$(date +%Y%m%d-%H%M%S).dmg"
DMG_PATH="$DMG_OUTPUT_DIR/$DMG_FILENAME"

echo "════════════════════════════════════════════════════════════"
echo "Lecture Reflector DMG Builder"
echo "════════════════════════════════════════════════════════════"
echo "Configuration: $BUILD_CONFIG"
echo "App Path: $APP_PATH"
echo "Output: $DMG_PATH"
echo ""

# Step 1: Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: App bundle not found at $APP_PATH"
    echo "   Please build the $BUILD_CONFIG configuration first:"
    echo "   xcodebuild -project $APP_NAME.xcodeproj -scheme $APP_NAME -configuration $BUILD_CONFIG -derivedDataPath \"$DERIVED_DATA_PATH\" build"
    exit 1
fi

# Step 2: Create releases directory
mkdir -p "$DMG_OUTPUT_DIR"
echo "✅ Created releases directory"

# Step 3: Create a temporary directory for DMG contents
TEMP_DMG_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DMG_DIR" EXIT

echo "✅ Created temporary directory: $TEMP_DMG_DIR"

# Step 4: Copy app to temporary directory
cp -r "$APP_PATH" "$TEMP_DMG_DIR/"
echo "✅ Copied app to temporary directory"

# Step 5: Create a symlink to Applications folder for user convenience
ln -s /Applications "$TEMP_DMG_DIR/Applications"
echo "✅ Created Applications folder shortcut"

# Step 6: Create the DMG
echo ""
echo "🔧 Creating DMG image..."

# Remove any existing DMG with the same name
if [ -f "$DMG_PATH" ]; then
    rm "$DMG_PATH"
fi

# Create DMG with custom settings
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$TEMP_DMG_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ DMG created successfully!"
echo "════════════════════════════════════════════════════════════"
echo "📦 Location: $DMG_PATH"
echo "📊 Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "Latest release:"
ls -lh "$DMG_OUTPUT_DIR/$APP_NAME-"* | tail -1 | awk '{print "  " $9 " (" $5 ")"}'
echo ""
