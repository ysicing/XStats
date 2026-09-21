#!/bin/bash
# 版本号使用“年.月.日.当日索引”，例如 2026.09.21.01；每次本地构建自动推进。
#
#   Scripts/version.sh            # 显示当前版本
#   Scripts/version.sh next       # 预览下一版本，不修改文件
#   Scripts/version.sh build      # 版本号和内部构建号各推进一次（task build 会自动调用）
#
# 当天首次构建从 01 开始，后续递增；跨日重置为 01。内部构建号持续递增、不归零。
set -euo pipefail
cd "$(dirname "$0")/.."

FILE=project.yml
version="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' "$FILE" | head -1)"
build="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([0-9]+)"?.*/\1/p' "$FILE" | head -1)"
today="$(date +%Y.%m.%d)"

set_value() {
  sed -i '' -E "s/^( *$1: *)\"?[0-9.]+\"?/\1\"$2\"/" "$FILE"
}

next_version() {
  local index=1
  if [[ "$version" =~ ^${today//./\.}\.([0-9]+)$ ]]; then
    index=$((10#${BASH_REMATCH[1]} + 1))
  fi
  printf '%s.%02d\n' "$today" "$index"
}

case "${1:-show}" in
  show) ;;
  next)
    next_version
    exit 0
    ;;
  build)
    version="$(next_version)"
    build=$(printf "%04d" $((10#$build + 1)))
    set_value MARKETING_VERSION "$version"
    set_value CURRENT_PROJECT_VERSION "$build"
    ;;
  *) echo "用法：Scripts/version.sh [show|next|build]" >&2; exit 1 ;;
esac
echo "$version ($(printf "%04d" $((10#$build))))"
