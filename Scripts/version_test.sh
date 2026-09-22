#!/bin/bash
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 每个用例都在干净的副本里跑：脚本会改写 project.yml，不能污染仓库
setup() {
  rm -rf "$WORK/case"
  mkdir -p "$WORK/case/Scripts"
  cp "$ROOT/Scripts/version.sh" "$WORK/case/Scripts/version.sh"
  cp "$ROOT/project.yml" "$WORK/case/project.yml"
  sed -i '' -E "s/(MARKETING_VERSION: *)\"?[0-9.]+\"?/\1\"$1\"/" "$WORK/case/project.yml"
  sed -i '' -E "s/(CURRENT_PROJECT_VERSION: *)\"?[0-9.]+\"?/\1\"$2\"/" "$WORK/case/project.yml"
  printf '%s\n' "$3" > "$WORK/case/CHANGELOG.md"
}

VALID_LOG='# 更新日志

## 1.0.0 · 2026-09-21

### 2026-09-21

#### 新增

- 示例条目。'

expect_output() {
  local actual="$1" expected="$2"
  [[ "$actual" == "$expected" ]] || { echo "期望 [$expected]，实际 [$actual]" >&2; exit 1; }
}

expect_project() {
  grep -q "MARKETING_VERSION: \"$1\"" "$WORK/case/project.yml" \
    || { echo "MARKETING_VERSION 不是 $1" >&2; exit 1; }
  grep -q "CURRENT_PROJECT_VERSION: \"$2\"" "$WORK/case/project.yml" \
    || { echo "CURRENT_PROJECT_VERSION 不是 $2" >&2; exit 1; }
}

# 期望失败，且失败后 project.yml 必须原样不动——发版脚本会在这之后接着跑，
# 留下半修改的版本文件比直接失败更难排查
expect_failure() {
  cp "$WORK/case/project.yml" "$WORK/before.yml"
  if (cd "$WORK/case" && Scripts/version.sh "$1" >/dev/null 2>&1); then
    echo "错误地接受了：$1（$2）" >&2
    exit 1
  fi
  cmp -s "$WORK/before.yml" "$WORK/case/project.yml" \
    || { echo "失败后 project.yml 被修改了（$2）" >&2; exit 1; }
}

# show 不修改任何文件
setup 1.0.0 109 "$VALID_LOG"
cp "$WORK/case/project.yml" "$WORK/before.yml"
expect_output "$(cd "$WORK/case" && Scripts/version.sh)" "1.0.0 (109)"
cmp -s "$WORK/before.yml" "$WORK/case/project.yml" || { echo "show 不应修改 project.yml" >&2; exit 1; }

# build 只推进构建号，公开版本号纹丝不动
setup 1.0.0 109 "$VALID_LOG"
expect_output "$(cd "$WORK/case" && Scripts/version.sh build)" "1.0.0 (110)"
expect_project 1.0.0 110
expect_output "$(cd "$WORK/case" && Scripts/version.sh build)" "1.0.0 (111)"
expect_project 1.0.0 111

# 旧的四位补零构建号按十进制读取并规范化：0109 → 110，不能被当成八进制
setup 2026.09.21.04 0109 "$VALID_LOG"
expect_output "$(cd "$WORK/case" && Scripts/version.sh build)" "2026.09.21.04 (110)"
expect_project 2026.09.21.04 110

# release 从 CHANGELOG 顶部取版本，同时推进构建号，stdout 只有版本号
setup 2026.09.21.04 0109 "$VALID_LOG"
expect_output "$(cd "$WORK/case" && Scripts/version.sh release)" "1.0.0"
expect_project 1.0.0 110

# 顶部还是“未发布”时必须失败：不能跳过它去用下面的旧版本
setup 1.0.0 109 '# 更新日志

## 未发布

## 0.6.1 · 2026-09-18'
expect_failure release "顶部为未发布"

# 日期版本号、前导零、不存在的日期、标题带尾缀都不是合法的 semver 标题
setup 1.0.0 109 '# 更新日志

## 2026.09.21.01 · 2026-09-21'
expect_failure release "日期式版本号"

setup 1.0.0 109 '# 更新日志

## 01.0.0 · 2026-09-21'
expect_failure release "数字段带前导零"

setup 1.0.0 109 '# 更新日志

## 1.0.0 · 2026-02-29'
expect_failure release "日期不存在"

setup 1.0.0 109 '# 更新日志

## 1.0.0 · 2026-09-21 补充'
expect_failure release "标题带多余尾缀"

setup 1.0.0 109 '# 更新日志

## 1.0.0-rc1 · 2026-09-21'
expect_failure release "prerelease 后缀"

# 构建号读不出来时两个子命令都要失败
setup 1.0.0 109 "$VALID_LOG"
sed -i '' -E 's/(CURRENT_PROJECT_VERSION: *)"[0-9]+"/\1"abc"/' "$WORK/case/project.yml"
expect_failure build "非数字构建号"
expect_failure release "非数字构建号"

# 已删除的子命令不能静默成功
setup 1.0.0 109 "$VALID_LOG"
expect_failure next "next 子命令已删除"
expect_failure tag "tag 子命令已删除"

echo "版本脚本测试通过"
