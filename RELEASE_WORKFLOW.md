# Lecture Reflector Release Workflow

**Created:** 2026-08-08  
**Release:** 0.1.0  
**Build:** Release

## ✅ Completed Tasks

### 1. Project Rename
- ✅ Renamed "MingJing project" → "Lecture Reflector project"
- ✅ Renamed `Mingjing/` → `LectureReflector/`
- ✅ Renamed `Mingjing.xcodeproj/` → `LectureReflector.xcodeproj/`
- ✅ Updated all 92 code references (Mingjing → LectureReflector, mingjing → lecture_reflector)
- ✅ Updated bundle ID: `com.kevinmiller.mingjing` → `com.kevinmiller.lecture_reflector`
- ✅ Regenerated Xcode project with `xcodegen generate`

### 2. Release Build
- ✅ Built Release configuration
- ✅ Code signed with Apple Development certificate (Team: YCTW9YH58J)
- ✅ Hardened runtime enabled
- ✅ App validated and registered with Launch Services

**Build Location:**
```
~/Library/Caches/LectureReflectorBuild/Build/Products/Release/LectureReflector.app
```

### 3. DMG Creation
- ✅ Created DMG disk image (Release build)
- ✅ Compressed with UDZO format, zlib-level=9
- ✅ Includes Applications folder shortcut for easy installation
- ✅ Size: 2.4M

**DMG Location:**
```
./releases/LectureReflector-20260808-090829.dmg
```

### 4. Build Workflow System

Created three layers of build automation:

#### **Layer 1: `build.sh` (Recommended)**
Main entry point - handles everything from building to DMG creation to app launching.

```bash
./build.sh dmg Release        # Build + create DMG (default)
./build.sh build Release      # Build only
./build.sh open Release       # Open built app
./build.sh open-dmg           # Open latest DMG
./build.sh releases           # List all releases
./build.sh clean              # Clean build cache
./build.sh -h                 # Show help
```

**Features:**
- Color-coded output (errors in red, success in green)
- Automatic DEVELOPER_DIR configuration
- Derived data outside project (avoids iCloud issues)
- Interactive help system

#### **Layer 2: `build_dmg.sh` (Advanced)**
Lower-level script for DMG creation. Automatically called by `build.sh`.

```bash
./build_dmg.sh Release        # Create DMG from Release build
./build_dmg.sh Debug          # Create DMG from Debug build
```

**Features:**
- Validates app exists before creating DMG
- Creates temporary staging directory
- Adds Applications symlink
- Preserves temp directory for debugging if needed

#### **Layer 3: `Makefile` (Traditional)**
For developers who prefer `make` commands. Provides targets for all build tasks.

```bash
make dmg                      # Build Release + create DMG (default)
make build-debug              # Build Debug only
make open-dmg                 # Open latest DMG
make clean                    # Clean all artifacts
make help                     # Show all targets
```

## 📋 Quick Reference

### Most Common Commands

```bash
# One-command build + DMG creation (recommended)
./build.sh

# Build only (faster for testing)
./build.sh build Release

# Build and open the app
./build.sh build Release && ./build.sh open

# Create DMG from existing build
./build_dmg.sh Release

# Clean everything and rebuild
./build.sh clean && ./build.sh dmg
```

### Using Makefile

```bash
# Same as ./build.sh (default)
make dmg

# Same as ./build.sh build Release
make build-release

# Same as ./build.sh open-dmg
make open-dmg
```

## 📂 Project Structure

```
Lecture Reflector project/
├── LectureReflector.xcodeproj/
├── LectureReflector/
│   ├── Sources/
│   ├── Resources/
│   └── LectureReflector.entitlements
├── project.yml
├── BUILD_GUIDE.md              # Detailed build documentation
├── RELEASE_WORKFLOW.md         # This file
├── build.sh                    # Main workflow script (USE THIS)
├── build_dmg.sh                # DMG creation script
├── Makefile                    # Traditional make targets
└── releases/
    └── LectureReflector-20260808-090829.dmg  # Latest DMG
```

## 🔧 Build Environment

The build scripts automatically configure:

- **Xcode:** `/Applications/Xcode.app/Contents/Developer`
- **Derived Data:** `~/Library/Caches/LectureReflectorBuild/` (outside project)
- **Code Signing:** Apple Development certificate (Kevin Miller, Team YCTW9YH58J)
- **Capabilities:**
  - Screen Recording (ScreenCaptureKit)
  - Camera access
  - Microphone access
  - Network (for WhisperKit model downloads)

## 📊 Build Configuration

From `project.yml`:

```yaml
name: LectureReflector
PRODUCT_BUNDLE_IDENTIFIER: com.kevinmiller.lecture_reflector
MARKETING_VERSION: "0.1.0"
CURRENT_PROJECT_VERSION: 1
deploymentTarget: macOS 14.0
```

## 🚀 Distribution

### For Users (via DMG)

1. Download the latest DMG from `releases/`
2. Open it (double-click)
3. Drag `LectureReflector` to the `Applications` folder
4. Launch from Applications folder or Launchpad

### For Developers

1. Clone the repository
2. Run: `./build.sh dmg Release`
3. Distribute `releases/LectureReflector-*.dmg`

### For CI/CD

Add to your workflow:

```bash
cd "Lecture Reflector project"
./build.sh dmg Release
# DMG now at: releases/LectureReflector-*.dmg
```

## 🔄 Future Updates

### To Update the Version

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

### To Customize DMG

Edit `build_dmg.sh` to add:
- Custom background image
- Custom volume icon
- Icon positioning
- Window size/position

Or install `create-dmg` for easier customization:

```bash
brew install create-dmg
# Then modify build_dmg.sh to use create-dmg instead of hdiutil
```

## 📝 Notes

- All build outputs are outside the project folder to avoid iCloud sync conflicts
- DMG files are timestamped for easy version tracking
- Build scripts are shell scripts (no external dependencies beyond macOS tools)
- Scripts are executable and well-documented with inline comments
- Success/error messages are color-coded for visibility

## ✨ What's New

**Build Workflow (2026-08-08):**
- [x] Automated Release build process
- [x] DMG creation with compression
- [x] Multi-layer build system (scripts + Makefile)
- [x] Color-coded output
- [x] Help documentation
- [x] Release archive system
- [x] Error validation
- [x] Clean build cache option

---

**Build System Version:** 1.0  
**Last Updated:** 2026-08-08  
**Next Review:** When version changes

---

**Lecture Reflector** is a product of Kevin Miller and Timely Snow LLC — [timelysnow.com](https://timelysnow.com)

© 2026 Timely Snow LLC. All rights reserved.


---

## Update 2026-10-14 (0.2.0)

- `./install.sh` builds Release, quits any running copy, replaces `/Applications/LectureReflector.app` and prints the installed version, whether the installed executable matches the build, and the signature check.
- `./autobuild.sh` is a watcher for Claude-driven builds: start it once in Terminal and leave it open. `.build-request` triggers a Release build; `.install-request` triggers `install.sh`. Results are in `build-output/`.
- See `DEV_REPORT_2026-10-14.md` for what changed in 0.2.0.
