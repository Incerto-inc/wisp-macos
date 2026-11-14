#!/usr/bin/env bash
# Build macOS AppIcon.icns (+ tray templates) from Resources/AppIcon-1024.png.
#
#   ./Scripts/make-icon.sh [source.png]
#
# Default source: Resources/AppIcon-1024.png (Incerto swan silhouette master).
# Produces:
#   Resources/AppIcon.iconset/*
#   Resources/AppIcon.appiconset/*  (same sizes; Contents.json preserved)
#   Resources/AppIcon.icns
#   Resources/tray/wispTemplate.png / @2x  (via make-tray-icon.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/Resources/AppIcon-1024.png}"
ICONSET="$ROOT/Resources/AppIcon.iconset"
APPICONSET="$ROOT/Resources/AppIcon.appiconset"
ICNS="$ROOT/Resources/AppIcon.icns"

if [[ ! -f "$SRC" ]]; then
  echo "error: no such file: $SRC" >&2
  exit 66
fi

dims=$(sips -g pixelWidth -g pixelHeight "$SRC" | awk '/pixel(Width|Height)/ {print $2}' | paste -sd'x' -)
width="${dims%x*}"
height="${dims#*x}"
if [[ "$width" != "$height" ]]; then
  echo "error: source must be square, got ${width}x${height}" >&2
  exit 65
fi
if (( width < 1024 )); then
  echo "error: source must be at least 1024x1024, got ${width}x${height}" >&2
  exit 65
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$APPICONSET"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$SRC" \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

# Keep appiconset in sync with iconset (Contents.json stays put).
for f in "$ICONSET"/*.png; do
  cp "$f" "$APPICONSET/$(basename "$f")"
done

iconutil --convert icns "$ICONSET" --output "$ICNS"

if [[ "$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")" != "$ROOT/Resources/AppIcon-1024.png" ]]; then
  sips -z 1024 1024 "$SRC" --out "$ROOT/Resources/AppIcon-1024.png" >/dev/null
fi

"$ROOT/Scripts/make-tray-icon.sh"

echo "wrote $ICNS"
