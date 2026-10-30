.PHONY: help build build-debug build-release dmg dmg-debug dmg-release clean open open-dmg releases

# Configuration
PROJECT_NAME := LectureReflector
XCODE_PROJECT := LectureReflector.xcodeproj
SCHEME := LectureReflector
DERIVED_DATA := $(HOME)/Library/Caches/LectureReflectorBuild
DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

# Default target
.DEFAULT_GOAL := help

help:
	@echo "Lecture Reflector Build System"
	@echo ""
	@echo "Available targets:"
	@echo "  make build              Build Release configuration"
	@echo "  make build-debug        Build Debug configuration"
	@echo "  make build-release      Build Release configuration"
	@echo ""
	@echo "  make dmg                Build Release + create DMG (default)"
	@echo "  make dmg-debug          Build Debug + create DMG"
	@echo "  make dmg-release        Build Release + create DMG"
	@echo ""
	@echo "  make open               Open Release app"
	@echo "  make open-dmg           Open latest DMG"
	@echo "  make releases           List all DMG releases"
	@echo ""
	@echo "  make clean              Clean all build artifacts"
	@echo "  make help               Show this help message"

# Build targets
build: build-release

build-debug:
	@echo "Building $(PROJECT_NAME) - Debug..."
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild \
		-project $(XCODE_PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-derivedDataPath $(DERIVED_DATA) \
		build
	@echo "✅ Debug build completed"

build-release:
	@echo "Building $(PROJECT_NAME) - Release..."
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild \
		-project $(XCODE_PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(DERIVED_DATA) \
		build
	@echo "✅ Release build completed"

# DMG targets
dmg: dmg-release

dmg-debug: build-debug
	@echo "Creating DMG from Debug build..."
	./build_dmg.sh Debug
	@echo "✅ DMG created"

dmg-release: build-release
	@echo "Creating DMG from Release build..."
	./build_dmg.sh Release
	@echo "✅ DMG created"

# Open targets
open: open-release

open-release:
	@open "$(DERIVED_DATA)/Build/Products/Release/$(PROJECT_NAME).app"

open-debug:
	@open "$(DERIVED_DATA)/Build/Products/Debug/$(PROJECT_NAME).app"

open-dmg:
	@latest_dmg=$$(ls -t releases/$(PROJECT_NAME)-*.dmg 2>/dev/null | head -1); \
	if [ -z "$$latest_dmg" ]; then \
		echo "❌ No DMG files found"; \
		exit 1; \
	fi; \
	open "$$latest_dmg"

releases:
	@echo "Available Releases:"
	@if [ -d releases ]; then \
		ls -lhS releases/$(PROJECT_NAME)-*.dmg 2>/dev/null | awk '{print "  " $$9 " (" $$5 ")"}' || echo "  No releases found"; \
	else \
		echo "  No releases directory"; \
	fi

# Clean targets
clean:
	@echo "Cleaning build artifacts..."
	rm -rf "$(DERIVED_DATA)"
	@echo "✅ Cleaned $(DERIVED_DATA)"

clean-dmg:
	@echo "Cleaning DMG files..."
	rm -rf releases/
	@echo "✅ Cleaned releases/"

clean-all: clean clean-dmg
	@echo "✅ All artifacts cleaned"

# Xcode project regeneration
xcodegen:
	@echo "Regenerating Xcode project from project.yml..."
	xcodegen generate
	@echo "✅ Xcode project regenerated"
