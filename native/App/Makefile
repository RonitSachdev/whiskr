# Whiskr, the native Mac app.
#   make run        build (Debug) and open the app
#   make build      build only
#   make test       run the logic tests (the Kit's and the meadow scene's; Swift Testing)
#   make release    the Release configuration
#   make dist       the Release app as an unsigned, zipped download with its checksum, in DIST
#   make project    regenerate Whiskr.xcodeproj from project.yml (needs xcodegen)
#   make icon       redraw the app icon from docs/logo.svg
#   make clean      remove the build folders
#
# Builds go to ~/Library/Developer/Xcode/DerivedData/Whiskr-make (the app) and ~/Library/Developer/Whiskr
# (tests and downloads), outside the source folder, so nothing runs from inside ~/Desktop or ~/Documents
# (folders macOS guards). Each can be pointed elsewhere: make build DERIVED=/some/folder. The meadow scene
# is the local package ../Scene, built with the app.
#
# The app is not signed: it carries only the ad-hoc signature the linker adds on Apple silicon.

CONFIG ?= Debug
DERIVED ?= $(HOME)/Library/Developer/Xcode/DerivedData/Whiskr-make
SCRATCH ?= $(HOME)/Library/Developer/Whiskr
TEST_BUILD ?= $(SCRATCH)/kit-tests
SCENE_TEST_BUILD ?= $(SCRATCH)/scene-tests
DIST ?= $(SCRATCH)/dist
APP = $(DERIVED)/Build/Products/$(CONFIG)/Whiskr.app
# SwiftTerm runs a small build plugin that writes its version; command-line builds trust it
# explicitly (Xcode asks once, with "Trust & Enable"). Packages.xcconfig optimises SwiftTerm in Debug
# builds too (a terminal's re-wrap on resize is 50 times slower without).
XCODEBUILD = xcodebuild -project Whiskr.xcodeproj -scheme Whiskr -derivedDataPath "$(DERIVED)" \
	-skipPackagePluginValidation -skipMacroValidation -destination 'platform=macOS,arch=arm64' -xcconfig Packages.xcconfig

.PHONY: run build release dist test test-kit test-scene project icon clean

build:
	$(XCODEBUILD) -configuration $(CONFIG) -quiet build
	@echo "Built: $(APP)"

run: build
	open "$(APP)"

release:
	$(MAKE) build CONFIG=Release

# The same archive the release workflow attaches to a draft GitHub release.
dist: release
	Scripts/package.sh "$(DERIVED)/Build/Products/Release/Whiskr.app" "$(DIST)"

test: test-kit test-scene

test-kit:
	swift test --package-path WhiskrKit --scratch-path "$(TEST_BUILD)"

test-scene:
	swift test --package-path ../Scene --scratch-path "$(SCENE_TEST_BUILD)"

project:
	xcodegen generate --spec project.yml

icon:
	swift Scripts/make-icon.swift ../../docs/logo.svg Whiskr/Assets.xcassets/AppIcon.appiconset

clean:
	rm -rf "$(DERIVED)" "$(SCRATCH)"
