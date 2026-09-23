#!/bin/bash
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail
cd "$(dirname "$0")/.."

compile="$(task --dry compile SIGN_ID= 2>&1)"
grep -q -- "-destination 'generic/platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO" <<< "$compile"
if grep -q 'x86_64' <<< "$compile"; then
  echo "默认构建不应包含 x86_64" >&2
  exit 1
fi
if grep -q -- '^  -quiet' <<< "$compile"; then
  echo "默认构建不应使用会产生 SwiftCompile 伪错误的 -quiet" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# appcast.py 只读它自己上一级目录的 CHANGELOG.md，没有路径参数。所以把脚本复制到
# 临时目录、在那里配一份 fixture：测试从此与仓库真实的版本历史无关——归档旧版本、
# 发布新版本都不会让它失效。
mkdir -p "$WORK/repo/Scripts"
cp Scripts/appcast.py "$WORK/repo/Scripts/appcast.py"
cat > "$WORK/repo/CHANGELOG.md" <<'LOG'
# 更新日志

## 9.9.9 · 2026-01-02

### 2026-01-02

#### 新增

- 在“设置 → 关于”提供服务条款和隐私政策，说明本机数据、更新统计、第三方联网功能及用户自行配置的 WebDAV 同步。
LOG
printf 'zip' > "$WORK/XStats-9.9.9-AppleSilicon.zip"
printf 'dmg' > "$WORK/XStats-9.9.9-AppleSilicon.dmg"
(cd "$WORK/repo" && python3 Scripts/appcast.py 9.9.9 110 https://example.test \
  "$WORK/XStats-9.9.9-AppleSilicon.zip" "$WORK/XStats-9.9.9-AppleSilicon.dmg") > "$WORK/appcast.json"
python3 - "$WORK/appcast.json" <<'PY'
import json
import sys

feed = json.load(open(sys.argv[1], encoding="utf-8"))
assert "intel" not in feed, feed
assert feed["url"].endswith("-AppleSilicon.zip"), feed
assert feed["dmg"].endswith("-AppleSilicon.dmg"), feed
assert feed["notes"], feed
assert feed["notes"] == ["在“设置 → 关于”提供服务条款和隐私政策"], feed
# 客户端点“查看更新日志”不能跳到上游 OpenStats 的站点
assert feed["changelog"] == "https://github.com/ysicing/xstats/blob/main/CHANGELOG.md", feed
PY
