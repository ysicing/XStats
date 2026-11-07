#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || {
  echo "需要 librsvg：brew install librsvg" >&2
  exit 1
}

SOURCE=Assets/branding/network-monitor/xstats-network-logo.svg
BRANDING=Assets/branding/network-monitor
APPICON=Apps/NetworkMonitor/App/Assets.xcassets/AppIcon.appiconset

for pixels in 16 32 64 128 256 512 1024 2048; do
  if [ "$pixels" -eq 1024 ]; then
    filename=xstats-network-logo.png
  else
    filename="xstats-network-logo-$pixels.png"
  fi
  rsvg-convert --width "$pixels" --height "$pixels" \
    --output "$BRANDING/$filename" "$SOURCE"
done

bash scripts/render_dock_icon.sh "$BRANDING/xstats-network-logo-2048.png" "$APPICON"

echo "已从 SVG 母版更新网络组件透明品牌 Logo 及近白底应用图标"
