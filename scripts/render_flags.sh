#!/bin/bash
# 把 Assets/flags-svg 里的国旗 SVG（flag-icons，MIT）用 librsvg 渲染成 PNG，放到应用包资源里。
# 应用不再直接读 SVG：系统 NSImage 的 SVG 渲染器对 flag-icons 里的嵌套 <use>、clipPath 等写法支持不好，
# 中国、乌兹别克斯坦等旗子会画错。PNG 为 64×48，够 16 pt @3x 显示。
#   brew install librsvg
#   scripts/render_flags.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=Assets/flags-svg
OUT=Packages/XStatsKit/Sources/XStatsUI/Resources/Flags
command -v rsvg-convert >/dev/null || { echo "需要 librsvg：brew install librsvg" >&2; exit 1; }
mkdir -p "$OUT"
count=0
for svg in "$SRC"/*.svg; do
  name="$(basename "${svg%.svg}")"
  rsvg-convert -w 64 -h 48 "$svg" -o "$OUT/$name.png"
  count=$((count + 1))
done
echo "已渲染 $count 面国旗到 $OUT"
