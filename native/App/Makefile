# Whiskr, the native Mac app.
#   make run        build the app as people get it (Release, optimised) and open it
#   make build      build only (CONFIG=Debug for a Debug build)
#   make debug      build the Debug configuration (unoptimised, with the test harness: --isolated, --script…)
#   make run-debug  build Debug and open it
#   make profile    Release's optimisation with the Debug test harness, for measuring (never shipped)
#   make perf       the profile build's isolated, invisible performance and tab checks, as a table
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

CONFIG ?= Release
DERIVED ?= $(HOME)/Library/Developer/Xcode/DerivedData/Whiskr-make
# The profile build has folders of its own, so it never replaces the app `make run` opens.
PROFILE_DERIVED ?= $(DERIVED)-profile
PERF_RUNS ?= $(SCRATCH)/perf
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

.PHONY: run build debug run-debug release profile perf dist test test-kit test-scene project icon clean

build:
	$(XCODEBUILD) -configuration $(CONFIG) -quiet build
	@echo "Built: $(APP)"

run: build
	open "$(APP)"

debug:
	$(MAKE) build CONFIG=Debug

run-debug: debug
	open "$(DERIVED)/Build/Products/Debug/Whiskr.app"

release:
	$(MAKE) build CONFIG=Release

# Optimised as Release, with the harness of Debug builds compiled into the app (Profile.xcconfig).
profile:
	xcodebuild -project Whiskr.xcodeproj -scheme Whiskr -derivedDataPath "$(PROFILE_DERIVED)" \
		-skipPackagePluginValidation -skipMacroValidation -destination 'platform=macOS,arch=arm64' -xcconfig Profile.xcconfig \
		-configuration Release -quiet build
	@echo "Built: $(PROFILE_DERIVED)/Build/Products/Release/Whiskr.app"

# Isolated, invisible runs of the profile build (Scripts/perf.sh): fails when a check fails or a
# measurement passes its limit.
perf: profile
	Scripts/perf.sh "$(PROFILE_DERIVED)/Build/Products/Release/Whiskr.app" "$(PERF_RUNS)"

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
	rm -rf "$(DERIVED)" "$(PROFILE_DERIVED)" "$(SCRATCH)"
