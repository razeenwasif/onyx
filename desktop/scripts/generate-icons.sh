#!/usr/bin/env bash
# Generate icon.png, icon.ico, icon.icns, and Linux hicolor icons from
# assets/electron-icon.svg.
# Requires ImageMagick ('magick' or 'convert') and (on macOS) 'iconutil'. The SVG
# is rasterized by Chromium (the project's Electron, after 'npm install') or by
# rsvg-convert; ImageMagick's own SVG renderer drops the orbit strokes.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(cd "$here/.." && pwd)"
svg="$root/assets/electron-icon.svg"

if [[ ! -f "$svg" ]]; then
  echo "SVG not found at $svg" >&2
  exit 1
fi

# Detect ImageMagick command
if command -v magick >/dev/null 2>&1; then
  IM_CMD="magick"
elif command -v convert >/dev/null 2>&1; then
  IM_CMD="convert"
else
  echo "Error: ImageMagick ('magick' or 'convert') is required to resize the icons." >&2
  exit 1
fi

mkdir -p "$here/build/icons"

# Render one 1024px master; every size below is a downscale of it.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
master="$tmp/master.png"
if [[ -x "$here/node_modules/.bin/electron" ]]; then
  echo "Rendering SVG with Electron..."
  (unset ELECTRON_RUN_AS_NODE; "$here/node_modules/.bin/electron" "$here/scripts/render-svg.cjs" "$svg" "$master" 1024)
elif command -v rsvg-convert >/dev/null 2>&1; then
  echo "Rendering SVG with rsvg-convert..."
  rsvg-convert -w 1024 -h 1024 "$svg" -o "$master"
else
  echo "Error: run 'npm install' (for Electron) or install rsvg-convert to render the SVG." >&2
  exit 1
fi

echo "Generating 512x512 icon.png..."
$IM_CMD "$master" -filter Lanczos -resize 512x512 "$here/build/icon.png"

echo "Generating hicolor icons..."
sizes=(16 24 32 48 64 128 256 512)
for s in "${sizes[@]}"; do
  $IM_CMD "$master" -filter Lanczos -resize "${s}x${s}" "$here/build/icons/${s}x${s}.png"
done

echo "Generating Windows icon.ico..."
$IM_CMD "$master" -define icon:auto-resize=256,128,64,48,32,16 "$here/build/icon.ico"

# On macOS, generate native .icns
if command -v iconutil >/dev/null 2>&1; then
  echo "Generating macOS icon.icns..."
  iconset="$here/build/icon.iconset"
  rm -rf "$iconset"
  mkdir -p "$iconset"

  $IM_CMD "$master" -filter Lanczos -resize 16x16     "$iconset/icon_16x16.png"
  $IM_CMD "$master" -filter Lanczos -resize 32x32     "$iconset/icon_16x16@2x.png"
  $IM_CMD "$master" -filter Lanczos -resize 32x32     "$iconset/icon_32x32.png"
  $IM_CMD "$master" -filter Lanczos -resize 64x64     "$iconset/icon_32x32@2x.png"
  $IM_CMD "$master" -filter Lanczos -resize 128x128   "$iconset/icon_128x128.png"
  $IM_CMD "$master" -filter Lanczos -resize 256x256   "$iconset/icon_128x128@2x.png"
  $IM_CMD "$master" -filter Lanczos -resize 256x256   "$iconset/icon_256x256.png"
  $IM_CMD "$master" -filter Lanczos -resize 512x512   "$iconset/icon_256x256@2x.png"
  $IM_CMD "$master" -filter Lanczos -resize 512x512   "$iconset/icon_512x512.png"
  $IM_CMD "$master" -filter Lanczos -resize 1024x1024 "$iconset/icon_512x512@2x.png"

  iconutil -c icns "$iconset" -o "$here/build/icon.icns"
  rm -rf "$iconset"
  echo "Successfully generated $here/build/icon.icns"
fi

echo "Icons generated successfully."
