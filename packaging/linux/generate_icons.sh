#!/usr/bin/env bash
#
# Writes linux/runner/resources/icons/<N>.png, the hicolor app icons the
# runner's CMake installs as share/icons/hicolor/<N>x<N>/apps/
# com.kapybara.kapynotes.png, and assets/branding/kapynotes_tray_linux.png. Run it after a brand change and commit the
# result; builds only copy the PNGs. Needs ImageMagick (convert, identify).
#
# Linux does not mask app icons the way macOS, iOS and Android do, so the
# source is the transparent rounded tile, not the full-bleed app-icon master.
# 16 to 64 px are lifted out of the designer's Windows .ico, whose small sizes
# are tuned to whole pixels; a filtered downscale of the 1024 px master blurs
# the eyes at those sizes. 128 px and up are scaled from the master.

set -euo pipefail

cd "$(dirname "$0")/../.."
ICO="windows/runner/resources/app_icon.ico"
MASTER="assets/branding/kapynotes_mark_soft.png"
DEST="linux/runner/resources/icons"

mkdir -p "$DEST"
rm -f "$DEST"/*.png

for size in 16 24 32 48 64; do
  frame="$(identify -format '%p %w\n' "$ICO" | awk -v s="$size" '$2 == s { print $1; exit }')"
  if [[ -z "$frame" ]]; then
    echo "error: $ICO has no ${size}x${size} frame" >&2
    exit 1
  fi
  convert "${ICO}[$frame]" -strip "PNG32:$DEST/$size.png"
done

for size in 128 256 512; do
  convert "$MASTER" -filter Lanczos -resize "${size}x${size}" -strip "PNG32:$DEST/$size.png"
done

# The tray indicator is the 64 px icon; see assets/branding/README.md.
cp "$DEST/64.png" assets/branding/kapynotes_tray_linux.png

identify -format '%f %wx%h\n' "$DEST"/*.png
