# Lecture Reflector Build & Release Guide

## Quick Start

### Build and create a DMG (recommended):
```bash
./build.sh dmg Release
```

### Build only:
```bash
./build.sh build Release
```

### Open the app:
```bash
./build.sh open Release
```

## Build Workflow Scripts

### `build.sh` — Main workflow (recommended)
The primary entry point for all build operations. Supports multiple commands:

```bash
./build.sh [command] [config]
```

**Commands:**
- `dmg [Debug|Release]` — Build app + create DMG (default: Release)
- `build [Debug|Release]` — Build app only (default: Release)
- `clean` — Clean build artifacts
- `open [Debug|Release]` — Open the built app (default: Release)
- `open-dmg` — Open the latest DMG
- `releases` — List all created DMGs
- `-h, --help` — Show help

**Examples:**
```bash
./build.sh                      # Build Release + create DMG (default)
./build.sh build Debug          # Build Debug configuration only
./build.sh dmg Debug            # Build Debug + create DMG
./build.sh clean                # Clean cache
./build.sh open-dmg             # Open latest DMG in Finder
./build.sh releases             # List all releases
```

### `build_dmg.sh` — DMG creation (advanced)
Lower-level script for creating DMG files. Used by `build.sh dmg`.

```bash
./build_dmg.sh [Debug|Release]
```

**Note:** Requires the app to already be built. Use `build.sh dmg` instead for a complete workflow.

## Build Output Locations

- **Built App:** `$HOME/Library/Caches/LectureReflectorBuild/Build/Products/{Debug|Release}/LectureReflector.app`
- **DMG Files:** `./releases/LectureReflector-YYYYMMDD-HHMMSS.dmg`

## Environment Setup

The build scripts automatically set:
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` — Points to the correct Xcode installation
- Derived data path outside the project (avoids iCloud sync issues): `$HOME/Library/Caches/LectureReflectorBuild`

### Manual Build (if not using scripts):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project LectureReflector.xcodeproj \
  -scheme LectureReflector \
  -configuration Release \
  -derivedDataPath "$HOME/Library/Caches/LectureReflectorBuild" \
  build
```

## DMG Creation Details

### What's in the DMG?
- `LectureReflector.app` — The application bundle
- `Applications/` — Shortcut to system Applications folder (drag-and-drop installation)

### DMG Format
- **Format:** UDZO (compressed, read-only)
- **Compression:** Level 9 (maximum)
- **Volume Name:** "LectureReflector"

### Customizing the DMG

To customize the DMG appearance (background, icon placement, etc.), edit `build_dmg.sh`:

```bash
# Example: Add background image
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$TEMP_DMG_DIR" \
    -background "Design/dmg-background.png" \
    ...
```

For interactive DMG customization, use `create-dmg` (install via Homebrew):
```bash
brew install create-dmg
```

Then modify `build_dmg.sh` to use `create-dmg` instead of `hdiutil`.

## Code Signing

- **Identity:** Apple Development: Kevin Miller (9U49CJ6J4B)
- **Team:** YCTW9YH58J
- **Entitlements:** `LectureReflector/LectureReflector.entitlements`
- **Signing Style:** Manual (configured in `project.yml`)

The app is automatically code-signed during build with hardened runtime enabled.

## Continuous Integration Setup (Optional)

To automate builds (e.g., GitHub Actions):

```yaml
- name: Build Release DMG
  run: |
    cd "Lecture Reflector project"
    ./build.sh dmg Release
    
- name: Upload DMG
  uses: actions/upload-artifact@v2
  with:
    name: LectureReflector-DMG
    path: releases/*.dmg
```

## Troubleshooting

### Build fails with "resource fork detritus not allowed"
The project folder is on iCloud-synced Desktop. Derived data is placed outside the project folder to avoid this. If you still see errors:
```bash
./build.sh clean
./build.sh dmg Release
```

### DMG creation fails
Ensure the Release build succeeded first:
```bash
./build.sh build Release
```

### App won't launch from DMG
Check code signing:
```bash
codesign -v "$HOME/Library/Caches/LectureReflectorBuild/Build/Products/Release/LectureReflector.app"
```

### Permission denied when running scripts
Make scripts executable:
```bash
chmod +x build.sh build_dmg.sh
```

## Release Checklist

- [ ] Update version in `project.yml` (MARKETING_VERSION)
- [ ] Build and test Debug version: `./build.sh build Debug`
- [ ] Build and test Release version: `./build.sh build Release`
- [ ] Create DMG: `./build.sh dmg Release`
- [ ] Test DMG installation (drag app to Applications, launch)
- [ ] Verify permissions (Camera, Microphone, Screen Recording) work
- [ ] Archive DMG for distribution

## Version Management

To update the app version:

1. Edit `project.yml`:
   ```yaml
   MARKETING_VERSION: "0.2.0"
   CURRENT_PROJECT_VERSION: 2
   ```

2. Regenerate Xcode project:
   ```bash
   xcodegen generate
   ```

3. Build new release:
   ```bash
   ./build.sh dmg Release
   ```

---

**Last Updated:** 2026-08-08  
**Build Scripts Version:** 1.0

---

**Lecture Reflector** is a product of Kevin Miller and Timely Snow LLC — [timelysnow.com](https://timelysnow.com)

© 2026 Timely Snow LLC. All rights reserved.
