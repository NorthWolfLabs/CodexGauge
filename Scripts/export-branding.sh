#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
cd "$root"
developer_dir="$(xcode-select -p)"
compiler="${developer_dir:h}/Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$compiler" ]] || { print -u2 'Icon Composer export tool is unavailable in the selected Xcode.'; exit 1; }
command -v magick >/dev/null || { print -u2 'ImageMagick is required to compress branding PNG exports.'; exit 1; }
# Pin the design generation: do not silently change artwork when updating Xcode.
mkdir -p TokenTach/Branding
for appearance in Light Dark; do
  rendition=Default
  [[ "$appearance" == Dark ]] && rendition=Dark
  "$compiler" TokenTach/AppIcon.icon --export-image \
    --output-file "TokenTach/Branding/TokenTach-$appearance.png" \
    --platform macOS --rendition "$rendition" --width 1024 --height 1024 --scale 1 --design-generation 27
  icon="TokenTach/Branding/TokenTach-$appearance.png"
  # Lossless re-encoding retains 16-bit RGBA pixels, transparency, and the color profile.
  magick "$icon" -define png:compression-level=9 "${icon:r}.compressed.png"
  mv "${icon:r}.compressed.png" "$icon"
  [[ $(stat -f %z "$icon") -lt 2000000 ]] || { print -u2 "$icon exceeds the 2 MB branding export budget."; exit 1; }
done
# Keep legacy catalog artwork derived from the same source, rather than a separate design.
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=''
    [[ "$scale" == 2 ]] && suffix='@2x'
    "$compiler" TokenTach/AppIcon.icon --export-image \
      --output-file "TokenTach/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}${suffix}.png" \
      --platform macOS --rendition Default --width "$size" --height "$size" --scale "$scale" --design-generation 27
  done
done
