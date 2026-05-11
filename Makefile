################################################################################
# Gridly — Build & Development Makefile
# Usage: make <target>
################################################################################

PRODUCT        := Gridly
BUNDLE_ID      := com.gridly.app
SCHEME         := Gridly
SCHEME_LOCAL   := GridlyLocal
SCHEME_PAD     := GridlyMobile
BUILD_DIR      := /tmp/GridlyBuild
RELEASE_DIR    := /tmp/GridlyRelease
ARCHIVE_PATH   := /tmp/Gridly.xcarchive
DMG_PATH       := $(HOME)/Desktop/Gridly.dmg

XCODEPROJ      := Gridly.xcodeproj
XCODEBUILD     := /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild

.PHONY: all setup generate build-local build-pad test dmg archive notarize clean open help

# ── Default ───────────────────────────────────────────────────────────────────

all: generate build-local

# ── Setup ─────────────────────────────────────────────────────────────────────

setup:
	@echo "→ Checking dependencies…"
	@which xcodegen >/dev/null 2>&1 || brew install xcodegen
	@which xcbeautify >/dev/null 2>&1 || brew install xcbeautify
	@echo "✓ Dependencies OK"

# ── Generate Xcode Project ────────────────────────────────────────────────────

generate: setup
	@echo "→ Generating Xcode project from project.yml…"
	xcodegen generate
	@echo "✓ $(XCODEPROJ) generated"

# ── Local build (ad-hoc signed, no Apple Developer account needed) ────────────

build-local: $(XCODEPROJ)
	@echo "→ Building $(PRODUCT) for local use (ad-hoc signed, Release)…"
	$(XCODEBUILD) \
		-project $(XCODEPROJ) \
		-scheme $(SCHEME_LOCAL) \
		-configuration Release \
		CONFIGURATION_BUILD_DIR=$(RELEASE_DIR) \
		| xcbeautify
	@echo "✓ App at $(RELEASE_DIR)/$(PRODUCT).app"
	@echo "  Drag to /Applications, then right-click → Open on first launch."

# ── iPad simulator build ──────────────────────────────────────────────────────

build-pad: $(XCODEPROJ)
	@echo "→ Building GridlyPad for iPad simulator…"
	$(XCODEBUILD) \
		-project $(XCODEPROJ) \
		-scheme $(SCHEME_PAD) \
		-sdk iphonesimulator \
		-configuration Debug \
		| xcbeautify

# ── Test ──────────────────────────────────────────────────────────────────────

test: $(XCODEPROJ)
	@echo "→ Running unit tests…"
	$(XCODEBUILD) test \
		-project $(XCODEPROJ) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS' \
		| xcbeautify

# ── DMG (local, ad-hoc signed) ───────────────────────────────────────────────

dmg: build-local
	@echo "→ Building DMG…"
	@rm -rf /tmp/GridlyDMG && mkdir /tmp/GridlyDMG
	@cp -R $(RELEASE_DIR)/$(PRODUCT).app /tmp/GridlyDMG/
	@ln -s /Applications /tmp/GridlyDMG/Applications
	@hdiutil create -volname "$(PRODUCT)" -srcfolder /tmp/GridlyDMG -ov -format UDRW -size 100m /tmp/GridlyRW.dmg
	@hdiutil attach /tmp/GridlyRW.dmg -readwrite -noverify -noautoopen -quiet
	@sleep 2
	@hdiutil detach "/Volumes/$(PRODUCT)" -force -quiet
	@hdiutil convert /tmp/GridlyRW.dmg -format UDZO -imagekey zlib-level=9 -o $(DMG_PATH)
	@rm -f /tmp/GridlyRW.dmg
	@echo "✓ DMG at $(DMG_PATH)"

# ── Archive (Release, requires Developer ID) ──────────────────────────────────

archive: $(XCODEPROJ)
	@echo "→ Archiving $(PRODUCT) (Release)…"
	@echo "   Requires: Developer ID Application certificate + DEVELOPMENT_TEAM set"
	$(XCODEBUILD) archive \
		-project $(XCODEPROJ) \
		-scheme $(SCHEME) \
		-configuration Release \
		-archivePath $(ARCHIVE_PATH) \
		ENABLE_HARDENED_RUNTIME=YES \
		| xcbeautify
	@echo "✓ Archive at $(ARCHIVE_PATH)"

# ── Notarize ──────────────────────────────────────────────────────────────────
# Required env vars: NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD

notarize: archive
	@echo "→ Submitting to Apple Notary Service…"
	xcrun notarytool submit $(DMG_PATH) \
		--apple-id "$(NOTARY_APPLE_ID)" \
		--team-id "$(NOTARY_TEAM_ID)" \
		--password "$(NOTARY_PASSWORD)" \
		--wait --verbose
	@echo "→ Stapling…"
	xcrun stapler staple $(DMG_PATH)
	@echo "✓ Notarized: $(DMG_PATH)"

# ── Open in Xcode ─────────────────────────────────────────────────────────────

open: generate
	open $(XCODEPROJ)

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	rm -rf $(BUILD_DIR) $(RELEASE_DIR) $(ARCHIVE_PATH) /tmp/GridlyDMG /tmp/GridlyRW.dmg
	rm -rf $(XCODEPROJ)
	@echo "✓ Cleaned"

# ── Help ──────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "Gridly Build System"
	@echo "═══════════════════"
	@echo "  make setup        Install build dependencies (xcodegen, xcbeautify)"
	@echo "  make generate     Generate Xcode project from project.yml"
	@echo "  make build-local  Build ad-hoc signed Release app (no Apple account needed)"
	@echo "  make build-pad    Build GridlyPad for iPad simulator"
	@echo "  make test         Run unit tests"
	@echo "  make dmg          Build drag-to-install DMG (ad-hoc signed)"
	@echo "  make archive      Build Release archive (requires Developer ID cert)"
	@echo "  make notarize     Notarize and staple DMG (requires env vars below)"
	@echo "  make open         Generate project and open in Xcode"
	@echo "  make clean        Remove all build artifacts"
	@echo ""
	@echo "Required env vars for 'make notarize':"
	@echo "  NOTARY_APPLE_ID     Apple ID email"
	@echo "  NOTARY_TEAM_ID      Apple Developer Team ID"
	@echo "  NOTARY_PASSWORD     App-specific password (appleid.apple.com)"
	@echo ""
