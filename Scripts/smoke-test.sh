#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twarge LLC
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/smoke"
XCFRAMEWORK="$ROOT_DIR/Vendor/Build/HDF5.xcframework"

mkdir -p "$BUILD_DIR"

COMMON_FLAGS=(
    -std=c11
    -I "$ROOT_DIR/Sources/HDF5Shim/include"
)

LINK_INPUTS=()

if [ -d "$XCFRAMEWORK" ]; then
    HDF5_LIBRARY="$(find "$XCFRAMEWORK" -name 'libhdf5.a' -print -quit)"
    HDF5_HEADERS="$(dirname "$HDF5_LIBRARY")/Headers"
    COMMON_FLAGS+=(-I "$HDF5_HEADERS")
    LINK_INPUTS+=("$HDF5_LIBRARY" -lz)
elif [ "${HIDEF_USE_SYSTEM_HDF5:-0}" = "1" ]; then
    read -r -a HDF5_CFLAGS <<< "$(pkg-config --cflags hdf5)"
    read -r -a HDF5_LIBS <<< "$(pkg-config --libs hdf5)"
    COMMON_FLAGS+=("${HDF5_CFLAGS[@]}")
    LINK_INPUTS+=("${HDF5_LIBS[@]}")
else
    echo "Missing $XCFRAMEWORK" >&2
    echo "Run Scripts/build-hdf5-xcframework.sh first." >&2
    exit 1
fi

xcrun clang "${COMMON_FLAGS[@]}" \
    "$ROOT_DIR/Sources/HDF5Shim/HiDeFHDF5.c" \
    "$ROOT_DIR/Tests/Smoke/SmokeTest.c" \
    "${LINK_INPUTS[@]}" \
    -o "$BUILD_DIR/hidef-smoke-test"

"$BUILD_DIR/hidef-smoke-test"
