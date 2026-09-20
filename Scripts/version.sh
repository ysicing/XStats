#!/bin/bash
# 版本号：营销版本 X.Y.Z 只在发布时改，构建号四位数字每次本地构建加一，显示为 “0.2.0 (0003)”。
#
#   Scripts/version.sh            # 显示当前版本
#   Scripts/version.sh build      # 构建号加一（make build 会自动调用）
#   Scripts/version.sh patch      # 小改发布：0.2.0 → 0.2.1
#   Scripts/version.sh minor      # 大改发布：0.2.1 → 0.3.0
#   Scripts/version.sh major      # 1.0.0 这类里程碑
#
# 构建号跨版本持续递增、不归零，保证每个安装包的 CFBundleVersion 都比之前的大。
set -euo pipefail
cd "$(dirname "$0")/.."

FILE=project.yml
version="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' "$FILE" | head -1)"
build="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([0-9]+)"?.*/\1/p' "$FILE" | head -1)"

set_value() {
  sed -i '' -E "s/^( *$1: *)\"?[0-9.]+\"?/\1\"$2\"/" "$FILE"
}

IFS=. read -r major minor patch <<< "$version"
case "${1:-show}" in
  show) ;;
  build)
    build=$(printf "%04d" $((10#$build + 1)))
    set_value CURRENT_PROJECT_VERSION "$build"
    ;;
  patch) version="$major.$minor.$((patch + 1))"; set_value MARKETING_VERSION "$version" ;;
  minor) version="$major.$((minor + 1)).0"; set_value MARKETING_VERSION "$version" ;;
  major) version="$((major + 1)).0.0"; set_value MARKETING_VERSION "$version" ;;
  *) echo "用法：Scripts/version.sh [show|build|patch|minor|major]" >&2; exit 1 ;;
esac
echo "$version ($(printf "%04d" $((10#$build))))"
