#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twarge LLC
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HDF5_SRC="$ROOT_DIR/Vendor/hdf5"
BUILD_ROOT="$ROOT_DIR/Vendor/Build"
XCFRAMEWORK="$BUILD_ROOT/HDF5.xcframework"
MACOS_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
IOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.0}"
PLATFORMS="${HIDEF_HDF5_PLATFORMS:-macos ios ios-simulator}"
PATH_REMAP_FLAGS="-ffile-prefix-map=$ROOT_DIR=. -fdebug-prefix-map=$ROOT_DIR=."

if [ ! -d "$HDF5_SRC/src" ]; then
    git -C "$ROOT_DIR" submodule update --init --recursive Vendor/hdf5
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake is required to build vendored HDF5" >&2
    exit 1
fi

if ! command -v ninja >/dev/null 2>&1; then
    echo "ninja is required to build vendored HDF5" >&2
    exit 1
fi

cmake_common_args() {
    local install_dir="$1"
    shift

    cmake -S "$HDF5_SRC" -B "$1" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install_dir" \
        -DCMAKE_C_FLAGS="$PATH_REMAP_FLAGS" \
        -DCMAKE_CXX_FLAGS="$PATH_REMAP_FLAGS" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DHDF5_BUILD_CPP_LIB=OFF \
        -DHDF5_BUILD_EXAMPLES=OFF \
        -DHDF5_BUILD_FORTRAN=OFF \
        -DHDF5_BUILD_HL_LIB=OFF \
        -DHDF5_BUILD_JAVA=OFF \
        -DHDF5_BUILD_TOOLS=OFF \
        -DHDF5_ENABLE_SZIP_SUPPORT=OFF \
        -DHDF5_ENABLE_ZLIB_SUPPORT=ON \
        -DHDF5_EXTERNALLY_CONFIGURED=ON \
        "${@:2}"
}

sanitize_hdf5_build_settings() {
    local build_dir="$1"
    local settings_file="$build_dir/src/H5build_settings.c"

    if [ -f "$settings_file" ]; then
        ROOT_DIR="$ROOT_DIR" perl -0pi -e 's/\Q$ENV{ROOT_DIR}\E/./g' "$settings_file"
    fi
}

build_variant() {
    local name="$1"
    local sdk="$2"
    local architectures="$3"
    local deployment_target="$4"
    local system_name="${5:-}"
    local build_dir="$BUILD_ROOT/hdf5-build-$name"
    local install_dir="$BUILD_ROOT/hdf5-install-$name"
    local embedded_install_prefix="/opt/twarge/hidef/hdf5/$name"
    local sysroot

    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    rm -rf "$build_dir" "$install_dir"

    local platform_args=(
        -DCMAKE_OSX_SYSROOT="$sysroot"
        -DCMAKE_OSX_ARCHITECTURES="$architectures"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target"
    )

    if [ -n "$system_name" ]; then
        platform_args+=(-DCMAKE_SYSTEM_NAME="$system_name")
    fi

    cmake_common_args "$embedded_install_prefix" "$build_dir" "${platform_args[@]}"
    sanitize_hdf5_build_settings "$build_dir"
    cmake --build "$build_dir" --config Release
    cmake --install "$build_dir" --config Release --prefix "$install_dir"

    local library="$install_dir/lib/libhdf5.a"
    local headers="$install_dir/include"

    if [ ! -f "$library" ]; then
        echo "Expected HDF5 static library was not produced: $library" >&2
        exit 1
    fi

    XCFRAMEWORK_ARGS+=(-library "$library" -headers "$headers")
}

rm -rf "$XCFRAMEWORK"
mkdir -p "$BUILD_ROOT"

XCFRAMEWORK_ARGS=()

for platform in $PLATFORMS; do
    case "$platform" in
        macos)
            build_variant macos macosx "arm64;x86_64" "$MACOS_DEPLOYMENT_TARGET"
            ;;
        ios)
            build_variant ios iphoneos arm64 "$IOS_DEPLOYMENT_TARGET" iOS
            ;;
        ios-simulator)
            build_variant ios-simulator iphonesimulator "arm64;x86_64" "$IOS_DEPLOYMENT_TARGET" iOS
            ;;
        *)
            echo "Unknown HDF5 platform: $platform" >&2
            echo "Use HIDEF_HDF5_PLATFORMS='macos ios ios-simulator' to choose slices." >&2
            exit 1
            ;;
    esac
done

if [ "${#XCFRAMEWORK_ARGS[@]}" -eq 0 ]; then
    echo "No HDF5 platforms were selected" >&2
    exit 1
fi

xcodebuild -create-xcframework "${XCFRAMEWORK_ARGS[@]}" -output "$XCFRAMEWORK"

echo "Built $XCFRAMEWORK"
