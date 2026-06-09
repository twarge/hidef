#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twarge LLC
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/Resources/IconSource/HiDeFIcon.svg"
APPICON_DIR="$ROOT_DIR/Resources/Assets.xcassets/AppIcon.appiconset"
ICONSET_DIR="$ROOT_DIR/Resources/AppIcon.iconset"
ICNS_PATH="$ROOT_DIR/Resources/AppIcon.icns"

if ! command -v magick >/dev/null 2>&1; then
    echo "ImageMagick is required to regenerate icon PNGs from $SOURCE" >&2
    exit 1
fi

mkdir -p "$APPICON_DIR" "$ICONSET_DIR"
find "$APPICON_DIR" -maxdepth 1 -name 'AppIcon-*.png' -delete
find "$ICONSET_DIR" -maxdepth 1 -name '*.png' -delete
rm -f "$ICNS_PATH"

for size in 16 20 29 32 40 58 60 64 80 87 120 128 152 167 180 256 512 1024; do
    magick -background white "$SOURCE" -resize "${size}x${size}" -alpha off -strip "$APPICON_DIR/AppIcon-${size}.png"
done

cp "$APPICON_DIR/AppIcon-16.png" "$ICONSET_DIR/icon_16x16.png"
cp "$APPICON_DIR/AppIcon-32.png" "$ICONSET_DIR/icon_16x16@2x.png"
cp "$APPICON_DIR/AppIcon-32.png" "$ICONSET_DIR/icon_32x32.png"
cp "$APPICON_DIR/AppIcon-64.png" "$ICONSET_DIR/icon_32x32@2x.png"
cp "$APPICON_DIR/AppIcon-128.png" "$ICONSET_DIR/icon_128x128.png"
cp "$APPICON_DIR/AppIcon-256.png" "$ICONSET_DIR/icon_128x128@2x.png"
cp "$APPICON_DIR/AppIcon-256.png" "$ICONSET_DIR/icon_256x256.png"
cp "$APPICON_DIR/AppIcon-512.png" "$ICONSET_DIR/icon_256x256@2x.png"
cp "$APPICON_DIR/AppIcon-512.png" "$ICONSET_DIR/icon_512x512.png"
cp "$APPICON_DIR/AppIcon-1024.png" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

echo "Generated app icons in $APPICON_DIR"
echo "Generated $ICNS_PATH"
