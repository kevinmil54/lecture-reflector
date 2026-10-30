#!/bin/bash
# Complete Build Workflow for Lecture Reflector
# Handles building the app, creating DMG, and managing releases

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="LectureReflector"
BUILD_CONFIG="${1:-Release}"
DERIVED_DATA_PATH="$HOME/Library/Caches/LectureReflectorBuild"
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ️  $1${NC}"
}

# Show usage
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Lecture Reflector Build Workflow"
    echo ""
    echo "Usage: ./build.sh [command] [options]"
    echo ""
    echo "Commands:"
    echo "  build [Debug|Release]   Build the app (default: Release)"
    echo "  dmg [Debug|Release]     Build app and create DMG (default: Release)"
    echo "  clean                   Clean build artifacts"
    echo "  open                    Open the Release app"
    echo "  open-dmg                Open the latest DMG file"
    echo "  releases                List all DMG releases"
    echo ""
    exit 0
fi

# Parse command
COMMAND="${1:-dmg}"
CONFIG="${2:-Release}"

case "$COMMAND" in
    build)
        print_header "Building Lecture Reflector - $CONFIG"
        export DEVELOPER_DIR="$DEVELOPER_DIR"
        xcodebuild -project "$PROJECT_DIR/LectureReflector.xcodeproj" \
            -scheme "$APP_NAME" \
            -configuration "$CONFIG" \
            -derivedDataPath "$DERIVED_DATA_PATH" \
            build
        print_success "Build completed"
        ;;

    dmg)
        print_header "Building Lecture Reflector DMG - $CONFIG"

        # First, build the app
        print_info "Step 1/2: Building app..."
        export DEVELOPER_DIR="$DEVELOPER_DIR"
        xcodebuild -project "$PROJECT_DIR/LectureReflector.xcodeproj" \
            -scheme "$APP_NAME" \
            -configuration "$CONFIG" \
            -derivedDataPath "$DERIVED_DATA_PATH" \
            build
        print_success "App built"

        # Then create DMG
        print_info "Step 2/2: Creating DMG..."
        "$PROJECT_DIR/build_dmg.sh" "$CONFIG"
        ;;

    clean)
        print_header "Cleaning build artifacts"
        rm -rf "$DERIVED_DATA_PATH"
        print_success "Cleaned build cache at $DERIVED_DATA_PATH"
        ;;

    open)
        print_header "Opening Lecture Reflector ($CONFIG)"
        APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIG/$APP_NAME.app"
        if [ -d "$APP_PATH" ]; then
            open "$APP_PATH"
            print_success "App opened"
        else
            print_error "App not found at $APP_PATH. Build it first: ./build.sh build $CONFIG"
            exit 1
        fi
        ;;

    open-dmg)
        print_header "Opening latest DMG"
        LATEST_DMG=$(ls -t "$PROJECT_DIR/releases/$APP_NAME-"*.dmg 2>/dev/null | head -1)
        if [ -f "$LATEST_DMG" ]; then
            open "$LATEST_DMG"
            print_success "Opened: $(basename $LATEST_DMG)"
        else
            print_error "No DMG files found in releases/ directory"
            exit 1
        fi
        ;;

    releases)
        print_header "Available Releases"
        if [ -d "$PROJECT_DIR/releases" ]; then
            ls -lh "$PROJECT_DIR/releases/$APP_NAME-"*.dmg 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' || print_error "No releases found"
        else
            print_error "releases/ directory not found"
            exit 1
        fi
        ;;

    *)
        print_error "Unknown command: $COMMAND"
        echo "Use './build.sh --help' for usage information"
        exit 1
        ;;
esac
