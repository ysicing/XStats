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

for points in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((points * scale))
    if [ "$scale" -eq 2 ]; then
      filename="icon_${points}x${points}@2x.png"
    else
      filename="icon_${points}x${points}.png"
    fi
    rsvg-convert --background-color '#FCFDFF' --width "$pixels" --height "$pixels" \
      --output "$APPICON/$filename" "$SOURCE"
  done
done

echo "已从 SVG 母版更新网络组件透明品牌 Logo 及近白底应用图标"
