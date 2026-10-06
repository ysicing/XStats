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

# 无证书的 CI 用临时签名：关闭团队验证所需的 runtime，正式签名路径仍必须保留。
adhoc="$(task --dry compile SIGN_ID=- 2>&1)"
grep -q 'CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=NO' <<< "$adhoc"
grep -q 'scripts/sign_sparkle.sh' <<< "$adhoc"
grep -q 'XSTATS_NETWORK_PROFILE=' <<< "$compile"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Hardened Runtime 在缺少日历 entitlement 时会直接拒绝 EventKit 授权，不显示系统弹窗。
python3 - <<'PY'
import plistlib

with open("App/XStats.entitlements", "rb") as source:
    entitlements = plistlib.load(source)
assert entitlements.get("com.apple.security.personal-information.calendars") is True, "缺少 EventKit 日历访问 entitlement"
assert entitlements.get("com.apple.developer.system-extension.install") is True
assert "content-filter-provider-systemextension" in entitlements.get("com.apple.developer.networking.networkextension", [])
with open("App/Info.plist", "rb") as source:
    info = plistlib.load(source)
for key in ("NSCalendarsFullAccessUsageDescription", "NSRemindersFullAccessUsageDescription"):
    assert info.get(key), f"缺少权限说明：{key}"
assert info.get("NSSystemExtensionUsageDescription")
with open("NetworkExtension/Info.plist", "rb") as source:
    extension = plistlib.load(source)
assert extension["CFBundlePackageType"] == "SYSX"
assert extension["NetworkExtension"]["NEProviderClasses"]["com.apple.networkextension.filter-data"].endswith(".ConnectionFilterProvider")
with open("NetworkExtension/XStatsNetworkExtension.entitlements", "rb") as source:
    entitlements = plistlib.load(source)
assert entitlements.get("com.apple.security.app-sandbox") is True
assert entitlements["com.apple.developer.networking.networkextension"] == ["content-filter-provider-systemextension"]
mach_service = extension["NetworkExtension"]["NEMachServiceName"]
groups = entitlements.get("com.apple.security.application-groups", [])
assert any(mach_service.startswith(group + ".") for group in groups), "NE Mach 服务必须位于扩展 App Group 命名空间中"
assert info["NetworkObservationMachService"] == mach_service, "App 与扩展的 Mach 服务名不一致"
with open("App/XStats.entitlements", "rb") as source:
    app_groups = plistlib.load(source).get("com.apple.security.application-groups", [])
assert all(group in app_groups for group in groups), "主 App 与扩展必须属于同一 IPC App Group"
PY

# appcast.py 只读它自己上一级目录的 CHANGELOG.md，没有路径参数。所以把脚本复制到
# 临时目录、在那里配一份 fixture：测试从此与仓库真实的版本历史无关——归档旧版本、
# 发布新版本都不会让它失效。
mkdir -p "$WORK/repo/scripts"
cp scripts/appcast.py "$WORK/repo/scripts/appcast.py"
cat > "$WORK/repo/CHANGELOG.md" <<'LOG'
# 更新日志

## 9.9.9 · 2026-01-02

### 2026-01-02

#### 新增

- 在“设置 → 关于”提供服务条款和隐私政策，说明本机数据、更新统计、第三方联网功能及用户自行配置的 WebDAV 同步。
LOG
printf 'zip' > "$WORK/XStats-9.9.9-AppleSilicon.zip"
printf 'dmg' > "$WORK/XStats-9.9.9-AppleSilicon.dmg"
mkdir -p "$WORK/XStats.app/Contents/Library/SystemExtensions/work.12306.xstats.app.networkextension.systemextension/Contents"
python3 - "$WORK/XStats.app" <<'PYEXT'
import plistlib, sys
from pathlib import Path
p = Path(sys.argv[1]) / "Contents/Library/SystemExtensions/work.12306.xstats.app.networkextension.systemextension/Contents/Info.plist"
p.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.15.0", "CFBundleVersion": "136"}))
PYEXT
(cd "$WORK/repo" && python3 scripts/appcast.py 9.9.9 110 https://example.test \
  "$WORK/XStats-9.9.9-AppleSilicon.zip" "$WORK/XStats-9.9.9-AppleSilicon.dmg" "$WORK/XStats.app") > "$WORK/appcast.json"
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
