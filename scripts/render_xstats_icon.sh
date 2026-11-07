#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || {
  echo "需要 librsvg：brew install librsvg" >&2
  exit 1
}

SOURCE=Assets/branding/xstats-logo.svg
BRANDING=Assets/branding
APPICON=Apps/XStats/App/Assets.xcassets/AppIcon.appiconset

for pixels in 16 32 64 128 256 512 1024 2048; do
  if [ "$pixels" -eq 1024 ]; then
    filename=xstats-logo.png
  else
    filename="xstats-logo-$pixels.png"
  fi
  rsvg-convert --width "$pixels" --height "$pixels" \
    --output "$BRANDING/$filename" "$SOURCE"
done

cp "$BRANDING/xstats-logo-512.png" Assets/icon.png
cp "$BRANDING/xstats-logo-256.png" Packages/XStatsKit/Sources/XStatsUI/Resources/Logos/xstats-logo.png
bash scripts/render_dock_icon.sh "$BRANDING/xstats-logo-2048.png" "$APPICON"

echo "已从 SVG 母版更新透明品牌 Logo、应用内标识及近白底应用图标"
