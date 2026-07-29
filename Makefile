# SPDX-FileCopyrightText: 2026 Twarge LLC
# SPDX-License-Identifier: Apache-2.0
#
# Single entry point for building HighDeF.
#
#   make            Build the app. Builds the vendored HDF5 dependency first if
#                   it is missing, then runs xcodebuild against the shared
#                   scheme. No -derivedDataPath override, so this is exactly the
#                   build (and the same DerivedData) you get from Build & Run in
#                   Xcode.
#   make run        Build and launch the macOS app.
#   make deps       Build only the vendored HDF5 XCFramework.
#   make clean      Clean the app build (xcodebuild clean).
#   make distclean  Also remove the vendored HDF5 XCFramework.
#
# Common overrides:
#   make CONFIGURATION=Release
#   make DESTINATION='generic/platform=iOS Simulator' XCODE_FLAGS=CODE_SIGNING_ALLOWED=NO

PROJECT          := HiDeF.xcodeproj
SCHEME           := HiDeF
CONFIGURATION    ?= Debug
DESTINATION      ?= platform=macOS
XCODE_FLAGS      ?=
HDF5_XCFRAMEWORK := Vendor/Build/HDF5.xcframework

# Deliberately no -derivedDataPath: use Xcode's shared DerivedData so `make`
# matches Build & Run exactly and shares its build cache with the IDE.
XCODEBUILD := xcodebuild \
  -project $(PROJECT) \
  -scheme $(SCHEME) \
  -configuration $(CONFIGURATION) \
  -destination '$(DESTINATION)' \
  $(XCODE_FLAGS)

.PHONY: all
all: app

# Build the vendored HDF5 XCFramework only when it is not already present.
$(HDF5_XCFRAMEWORK):
	Scripts/build-hdf5-xcframework.sh

.PHONY: deps
deps: $(HDF5_XCFRAMEWORK)

# Build the app with Xcode (same as Build & Run). Builds deps first if needed.
.PHONY: app build
app build: deps
	$(XCODEBUILD) build

# Build and launch the macOS app from Xcode's DerivedData (the same bundle the
# IDE runs). The product path is resolved from the project's build settings.
.PHONY: run
run: app
	@app="$$($(XCODEBUILD) -showBuildSettings 2>/dev/null | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = /{d=$$2} /^[[:space:]]*FULL_PRODUCT_NAME = /{n=$$2} END{print d "/" n}')" && echo "Launching $$app" && open "$$app"

# Clean the app build products (matches Product > Clean Build Folder).
.PHONY: clean
clean:
	$(XCODEBUILD) clean

# Clean the app build and remove the vendored HDF5 XCFramework.
.PHONY: distclean
distclean: clean
	rm -rf $(HDF5_XCFRAMEWORK)

.PHONY: help
help:
	@echo 'HighDeF build targets:'
	@echo '  make            Build the app (builds HDF5 dependency first if needed)'
	@echo '  make run        Build and launch the macOS app'
	@echo '  make deps       Build the vendored HDF5 XCFramework'
	@echo '  make clean      Clean the app build (xcodebuild clean)'
	@echo '  make distclean  Also remove the HDF5 XCFramework'
	@echo ''
	@echo 'Overrides: CONFIGURATION (Debug/Release), DESTINATION, XCODE_FLAGS'
