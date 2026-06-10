#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twarge LLC
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
INTERMEDIATES="$BUILD_DIR/intermediates"
APP_DIR="$BUILD_DIR/HiDeF.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
XCFRAMEWORK="$ROOT_DIR/Vendor/Build/HDF5.xcframework"
CODESIGN_IDENTITY="${HIDEF_CODE_SIGN_IDENTITY:--}"

mkdir -p "$INTERMEDIATES" "$MACOS_DIR" "$RESOURCES_DIR"
rm -f "$MACOS_DIR/HiDeF" "$INTERMEDIATES/HiDeFHDF5.o"
mkdir -p "$INTERMEDIATES/ModuleCache"

SWIFT_SOURCES=()
while IFS= read -r source; do
    SWIFT_SOURCES+=("$source")
done < <(find "$ROOT_DIR/Sources/HiDeF" -name '*.swift' -print | sort)

COMMON_CFLAGS=(
    -std=c11
    -mmacosx-version-min="$DEPLOYMENT_TARGET"
    -I "$ROOT_DIR/Sources/HDF5Shim/include"
)

COMMON_SWIFT_FLAGS=(
    -swift-version 5
    -O
    -module-name hidef
    -I "$ROOT_DIR/Sources/HDF5Shim/include"
    -Xcc "-fmodules-cache-path=$INTERMEDIATES/ModuleCache"
    -import-objc-header "$ROOT_DIR/Sources/HiDeF/HiDeF-Bridging-Header.h"
)

LINK_INPUTS=()

if [ -d "$XCFRAMEWORK" ]; then
    HDF5_LIBRARY="$(find "$XCFRAMEWORK" -name 'libhdf5.a' -print -quit)"
    if [ -z "$HDF5_LIBRARY" ]; then
        echo "Could not find libhdf5.a inside $XCFRAMEWORK" >&2
        exit 1
    fi
    HDF5_HEADERS="$(dirname "$HDF5_LIBRARY")/Headers"
    COMMON_CFLAGS+=(-I "$HDF5_HEADERS")
    COMMON_SWIFT_FLAGS+=(-I "$HDF5_HEADERS")
    LINK_INPUTS+=("$HDF5_LIBRARY" -lz)
elif [ "${HIDEF_USE_SYSTEM_HDF5:-0}" = "1" ]; then
    if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists hdf5; then
        echo "HIDEF_USE_SYSTEM_HDF5=1 requires pkg-config hdf5 metadata" >&2
        exit 1
    fi
    # Homebrew paths contain no spaces; this branch is a developer fallback only.
    read -r -a HDF5_CFLAGS <<< "$(pkg-config --cflags hdf5)"
    read -r -a HDF5_LIBS <<< "$(pkg-config --libs hdf5)"
    COMMON_CFLAGS+=("${HDF5_CFLAGS[@]}")
    COMMON_SWIFT_FLAGS+=("${HDF5_CFLAGS[@]}")
    LINK_INPUTS+=("${HDF5_LIBS[@]}")
else
    echo "Missing $XCFRAMEWORK" >&2
    echo "Run Scripts/build-hdf5-xcframework.sh first, or set HIDEF_USE_SYSTEM_HDF5=1 for a local developer build." >&2
    exit 1
fi

xcrun clang "${COMMON_CFLAGS[@]}" \
    -c "$ROOT_DIR/Sources/HDF5Shim/HiDeFHDF5.c" \
    -o "$INTERMEDIATES/HiDeFHDF5.o"

xcrun swiftc "${COMMON_SWIFT_FLAGS[@]}" \
    "${SWIFT_SOURCES[@]}" \
    "$INTERMEDIATES/HiDeFHDF5.o" \
    "${LINK_INPUTS[@]}" \
    -framework AppKit \
    -framework SwiftUI \
    -o "$MACOS_DIR/HiDeF"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
if [ -f "$ROOT_DIR/Resources/ThirdPartyLicenses.txt" ]; then
    cp "$ROOT_DIR/Resources/ThirdPartyLicenses.txt" "$RESOURCES_DIR/ThirdPartyLicenses.txt"
fi
if [ -f "$ROOT_DIR/LICENSE" ]; then
    cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"
fi
if [ -f "$ROOT_DIR/Resources/Demo/demo.h5" ]; then
    cp "$ROOT_DIR/Resources/Demo/demo.h5" "$RESOURCES_DIR/demo.h5"
fi
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

if [ "${HIDEF_SKIP_CODESIGN:-0}" != "1" ]; then
    xcrun codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none \
        --entitlements "$ROOT_DIR/Resources/HiDeF.entitlements" "$APP_DIR"
fi

echo "Built $APP_DIR"
