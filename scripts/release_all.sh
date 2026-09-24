#!/bin/bash
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

# 一键执行完整发版：测试 → 签名公证构建 → 提交推送版本元数据 → 发布外部制品。
# 调用这个脚本即授权本次 release commit、push、GitHub Release、对象存储、版本 API 与 Homebrew 写入。
set -Eeuo pipefail
cd "$(dirname "$0")/.."

if [ -z "${XSTATS_RELEASE_TOKEN:-}" ]; then
  echo "error: XSTATS_RELEASE_TOKEN 不能为空，一键发布尚未开始。" >&2
  exit 1
fi

BRANCH="$(git symbolic-ref --quiet --short HEAD)" \
  || { echo "error: 当前不是可发布的分支检出。" >&2; exit 1; }
[ "$BRANCH" = main ] \
  || { echo "error: 一键发布只能从 main 执行，当前是 ${BRANCH}。" >&2; exit 1; }

git fetch --quiet origin main
HEAD_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse origin/main)"
[ "$HEAD_SHA" = "$REMOTE_SHA" ] \
  || { echo "error: HEAD 与 origin/main 不一致，请先处理未推送或远端更新。" >&2; exit 1; }

HEADING="$(grep -m1 '^## ' CHANGELOG.md || true)"
if [[ "$HEADING" =~ ^##[[:space:]](0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)[[:space:]]·[[:space:]][0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
else
  echo "error: CHANGELOG.md 顶部不是正式 semver 版本标题：${HEADING:-（没有二级标题）}" >&2
  exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/v${VERSION}" >/dev/null 2>&1; then
  echo "error: v${VERSION} 已存在；若是恢复中断的发布，请运行 task publish。" >&2
  exit 1
fi

RECOVERY=""
on_error() {
  local status=$?
  case "$RECOVERY" in
    push)
      echo "error: release commit 已创建但尚未确认推送成功；请先运行 git push origin main。" >&2
      ;;
    publish)
      echo "error: release commit 已推送；请修复外部问题后运行 task publish 续跑，不要再次执行 release-all。" >&2
      ;;
  esac
  exit "$status"
}
trap on_error ERR

# 在投入签名和公证时间前拒绝任何未提交源码；版本元数据仍可按发布流程保持未提交。
python3 scripts/release_provenance.py prepare >/dev/null
task test
task release

BUILT_VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml | head -1)"
[ "$BUILT_VERSION" = "$VERSION" ] \
  || { echo "error: 构建版本 $BUILT_VERSION 与 CHANGELOG 版本 $VERSION 不一致。" >&2; exit 1; }

# 构建后再次检查，防止构建工具或并行编辑把源码变化混入 release commit。
python3 scripts/release_provenance.py prepare >/dev/null
RELEASE_FILES=(
  project.yml
  CHANGELOG.md
  README.md
  README.en.md
  README.ja.md
  README.ko.md
  Assets/readme/activity.svg
  Assets/readme/activity.zh.svg
)
git add -- "${RELEASE_FILES[@]}"
if git diff --cached --quiet; then
  echo "error: 没有可提交的发布元数据。" >&2
  exit 1
fi

git commit -m "chore(release): 发布 ${VERSION}"
RECOVERY=push
git push origin main
RECOVERY=publish
./scripts/publish_release.sh
RECOVERY=""

echo "✅ XStats ${VERSION} 完整发布完成"
