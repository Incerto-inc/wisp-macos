#!/usr/bin/env bash
# Draw menu-bar template glyph: crisp Incerto swan silhouette (black RGB + alpha mask).
# macOS recolours template images for light/dark menu bar.
#
#   ./Scripts/make-tray-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAY="$ROOT/Resources/tray"
SVG="$ROOT/Resources/brand/incerto-swan-symbol-small.svg"
mkdir -p "$TRAY"

if [[ ! -f "$SVG" ]]; then
  echo "error: missing swan SVG: $SVG" >&2
  exit 66
fi

SS=512
TMP="$(mktemp -d)"
MASK="$TMP/mask.png"

# White swan on black — becomes the alpha channel after resize.
# Official symbol-small is already cropped for tab/icon scale; hard edges, no blur.
magick -background none -density 400 "$SVG" \
  -resize $((SS * 86 / 100))x$((SS * 86 / 100)) \
  -fill white -colorize 100% \
  -gravity center -background black -extent ${SS}x${SS} \
  -alpha off \
  "$MASK"

for pair in "16:wispTemplate.png" "32:wispTemplate@2x.png"; do
  size="${pair%%:*}"
  name="${pair##*:}"
  inner=$((size - 2))
  # RGB black + alpha from resized mask; 1px margin.
  magick \( -size "${size}x${size}" xc:black \) \
    \( "$MASK" -resize "${inner}x${inner}" -gravity center -background black -extent "${size}x${size}" \) \
    -alpha off -compose CopyOpacity -composite \
    PNG32:"$TRAY/$name"
done

mean_a=$(magick "$TRAY/wispTemplate@2x.png" -alpha extract -format "%[fx:mean]" info:)
if ! awk "BEGIN { exit !($mean_a > 0.02 && $mean_a < 0.9) }"; then
  echo "error: tray alpha looks flat (mean=$mean_a); refusing to write broken template" >&2
  rm -rf "$TMP"
  exit 1
fi

rm -rf "$TMP"
echo "wrote $TRAY/wispTemplate.png"
echo "wrote $TRAY/wispTemplate@2x.png (alpha mean=$mean_a)"
