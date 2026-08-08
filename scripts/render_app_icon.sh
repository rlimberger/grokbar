#!/usr/bin/env bash
# Regenerate AppIcon.png (if renderer present), all appiconset sizes, and AppIcon.icns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$ROOT/Resources/AppIcon.png"
ICONSET="$ROOT/Assets.xcassets/AppIcon.appiconset"
BUILD_SET="$ROOT/build/AppIcon.iconset"
ICNS="$ROOT/Resources/AppIcon.icns"
RENDER_SWIFT="$ROOT/scripts/render_app_icon.swift"

if [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
elif [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# Optional: rebuild master artwork from Grok SVG + usage pill
if [[ -f "$RENDER_SWIFT" ]]; then
  echo "Rendering master AppIcon from $RENDER_SWIFT …"
  swiftc -O -o /tmp/render_grokbar_icon "$RENDER_SWIFT"
  /tmp/render_grokbar_icon "$ROOT"
fi

if [[ ! -f "$MASTER" ]]; then
  echo "Missing $MASTER" >&2
  exit 1
fi

make_size() {
  local dest_dir="$1" name="$2" px="$3"
  local tmp
  tmp="$(mktemp /tmp/grokbar-icon.XXXXXX.png)"
  sips -z "$px" "$px" "$MASTER" --out "$tmp" >/dev/null
  if ! sips -s format png --deleteColorManagementProperties "$tmp" --out "$dest_dir/$name" >/dev/null 2>&1; then
    cp "$tmp" "$dest_dir/$name"
  fi
  rm -f "$tmp"
}

mkdir -p "$ICONSET"
rm -rf "$BUILD_SET"
mkdir -p "$BUILD_SET"

for dest in "$ICONSET" "$BUILD_SET"; do
  make_size "$dest" "icon_16x16.png" 16
  make_size "$dest" "diana.k@example.org" 32
  make_size "$dest" "icon_32x32.png" 32
  make_size "$dest" "ivan.p@example.net" 64
  make_size "$dest" "icon_128x128.png" 128
  make_size "$dest" "wendy.h@example.net" 256
  make_size "$dest" "icon_256x256.png" 256
  make_size "$dest" "wendy.h@example.net" 512
  make_size "$dest" "icon_512x512.png" 512
  make_size "$dest" "walt.e@example.net" 1024
done

cat > "$ICONSET/Contents.json" << 'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "diana.k@example.org", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "ivan.p@example.net", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "wendy.h@example.net", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "wendy.h@example.net", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "walt.e@example.net", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

iconutil -c icns "$BUILD_SET" -o "$ICNS"
echo "Updated:"
echo "  $MASTER"
echo "  $ICNS"
echo "  $ICONSET"
