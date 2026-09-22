#!/bin/bash
# Copyright (c) 2026 GiantAccel, LLC
# XStats modifications Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
# See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

# 公开版本号是标准 semver，真源是 CHANGELOG.md 顶部的 “## X.Y.Z · YYYY-MM-DD”；
# 内部构建号是单调递增的整数，与日期无关。
#
#   Scripts/version.sh          # 显示当前版本和构建号
#   Scripts/version.sh build    # 只推进构建号（task build 会自动调用）
#   Scripts/version.sh release  # 按 CHANGELOG 写入公开版本号并推进构建号，只输出版本号
set -euo pipefail
cd "$(dirname "$0")/.."

FILE=project.yml
CHANGELOG=CHANGELOG.md
version="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' "$FILE" | head -1)"
build="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([0-9]+)"?.*/\1/p' "$FILE" | head -1)"

set_value() {
  sed -i '' -E "s/^( *$1: *)\"?[0-9.]+\"?/\1\"$2\"/" "$FILE"
}

# 旧值可能带前导零（如 0109），用 10# 强制按十进制读，避免被当成八进制
next_build() {
  [[ "$build" =~ ^[0-9]+$ ]] || { echo "无法从 $FILE 读出数字构建号：${build:-（空）}" >&2; return 1; }
  printf '%d\n' "$((10#$build + 1))"
}

# 只认 CHANGELOG 的第一个二级标题：顶部还是“未发布”时必须失败，
# 不能跳过它去匹配下面已经发过的旧版本
changelog_version() {
  local heading date
  heading="$(grep -m1 '^## ' "$CHANGELOG" || true)"
  [[ "$heading" =~ ^##[[:space:]](0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)[[:space:]]·[[:space:]]([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]] || {
    echo "$CHANGELOG 顶部不是正式版本标题：${heading:-（没有二级标题）}" >&2
    echo "发版前请把 “## 未发布” 改成 “## X.Y.Z · YYYY-MM-DD”。" >&2
    return 1
  }
  date="${BASH_REMATCH[4]}"
  # BSD date 会把 2026-02-29 规整成 2026-03-01 而不是报错，所以回读比对
  [[ "$(date -j -f '%Y-%m-%d' "$date" '+%Y-%m-%d' 2>/dev/null)" == "$date" ]] || {
    echo "$CHANGELOG 顶部的日期不存在：$date" >&2
    return 1
  }
  printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

case "${1:-show}" in
  show)
    echo "$version ($build)"
    ;;
  build)
    build="$(next_build)"
    set_value CURRENT_PROJECT_VERSION "$build"
    echo "$version ($build)"
    ;;
  release)
    # 先把两项都算出来再落盘：中途失败不留下半修改的 project.yml
    version="$(changelog_version)"
    build="$(next_build)"
    set_value MARKETING_VERSION "$version"
    set_value CURRENT_PROJECT_VERSION "$build"
    # 只输出版本号：Scripts/release.sh 直接拿它拼安装包文件名
    echo "$version"
    ;;
  *)
    echo "用法：Scripts/version.sh [show|build|release]" >&2
    exit 1
    ;;
esac
