#!/bin/bash
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

APP="$1"
IDENTITY="${2:--}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${3:-}"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
case "$APP_ID" in
  work.12306.xstats.app) EXPECTED_MODE=main ;;
  work.12306.xstats.networkmonitor) EXPECTED_MODE=network-component ;;
  *) echo "error: 未知应用 Bundle ID：$APP_ID" >&2; exit 1 ;;
esac
MODE="${MODE:-$EXPECTED_MODE}"
[ "$MODE" = "$EXPECTED_MODE" ] || { echo "error: 签名模式与应用 Bundle ID 不一致" >&2; exit 1; }
SYSTEM_EXTENSION="$APP/Contents/Library/SystemExtensions/work.12306.xstats.app.networkextension.systemextension"
if [ "$MODE" = network-component ]; then
  [ -d "$SYSTEM_EXTENSION" ] || { echo "error: 网络组件未嵌入网络系统扩展" >&2; exit 1; }
  APP_ENTITLEMENTS="$ROOT/NetworkMonitorApp/XStatsNetworkMonitor.entitlements"
else
  [ ! -d "$APP/Contents/Library/SystemExtensions" ] || { echo "error: 主应用不得嵌入系统扩展" >&2; exit 1; }
  APP_ENTITLEMENTS="$ROOT/App/XStats.entitlements"
fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$FRAMEWORK" ] || { echo "error: 应用未嵌入 Sparkle.framework" >&2; exit 1; }
STAMP=(--timestamp)
OPTIONS=(--options runtime)
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  IDENTITY="-"
  STAMP=(--timestamp=none)
  OPTIONS=(--options 0)
elif ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  # Xcode 只在取得团队 ID 时签名子组件；证书不可用时不能再按正式分支只重签外层。
  echo "error: 签名证书 $IDENTITY 不在钥匙串有效证书中（过期、吊销或缺少中间证书）；本地构建可设置 SIGN_ID=- 使用临时签名" >&2
  exit 1
fi

# 官方框架包含 Intel 切片；只修改嵌入副本，保持 Swift Package 原始制品完整。
for binary in "$FRAMEWORK/Versions/Current/Sparkle" \
              "$FRAMEWORK/Versions/Current/Autoupdate" \
              "$FRAMEWORK/Versions/Current/Updater.app/Contents/MacOS/Updater" \
              "$FRAMEWORK/Versions/Current/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
              "$FRAMEWORK/Versions/Current/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"; do
  if [ "$(lipo -archs "$binary")" != arm64 ]; then
    lipo "$binary" -thin arm64 -output "$binary"
  fi
  [ "$(lipo -archs "$binary")" = arm64 ] || { echo "error: $binary 不是 arm64" >&2; exit 1; }
done

# Xcode 的 Embed & Sign 仅重签框架外层；官方二进制中的安装进程/XPC 仍需使用本应用身份。
# 逐层从内到外签名，保留根应用与系统扩展已有的 entitlement，不使用 --deep 代替正确的顺序。
for component in "$FRAMEWORK/Versions/Current/XPCServices/Downloader.xpc" \
                 "$FRAMEWORK/Versions/Current/XPCServices/Installer.xpc" \
                 "$FRAMEWORK/Versions/Current/Updater.app" \
                 "$FRAMEWORK/Versions/Current/Autoupdate"; do
  [ -e "$component" ] || { echo "error: 缺少 Sparkle 辅助程序 $component" >&2; exit 1; }
  codesign --force --sign "$IDENTITY" "${STAMP[@]}" "${OPTIONS[@]}" "$component"
done
codesign --force --sign "$IDENTITY" "${STAMP[@]}" "${OPTIONS[@]}" "$FRAMEWORK"
if [ "$IDENTITY" = "-" ]; then
  # 无团队的临时签名无法通过 Hardened Runtime 的动态库团队校验，仅本地/CI 关闭 runtime。
  # Xcode 的无证书路径不签名，由此处补齐自身二进制及 entitlement；线上安装仍禁止此构建。
  if [ "$MODE" = network-component ]; then
    codesign --force --sign - --timestamp=none --options 0 --entitlements "$ROOT/NetworkExtension/XStatsNetworkExtension.entitlements" "$SYSTEM_EXTENSION"
  else
    codesign --force --sign - --timestamp=none --options 0 "$APP/Contents/MacOS/XStatsHelper"
    codesign --force --sign - --timestamp=none --options 0 --entitlements "$ROOT/Widget/XStatsWidget.entitlements" "$APP/Contents/PlugIns/XStatsWidget.appex"
  fi
  # 临时签名不具备受 profile 约束的网络权限，仅用于 UI/CI；主 App 必须仍可启动。
  # 签名团队缺失时，启用查看的入口也会拒绝提交系统扩展激活请求。
  PREVIEW_ENTITLEMENTS="$(mktemp)"
  trap 'rm -f "$PREVIEW_ENTITLEMENTS"' EXIT
  python3 - "$APP_ENTITLEMENTS" "$PREVIEW_ENTITLEMENTS" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as source:
    entitlements = plistlib.load(source)
for key in ("com.apple.developer.system-extension.install", "com.apple.developer.networking.networkextension"):
    entitlements.pop(key, None)
with open(sys.argv[2], "wb") as target:
    plistlib.dump(entitlements, target)
PY
  codesign --force --sign - --timestamp=none --options 0 --entitlements "$PREVIEW_ENTITLEMENTS" "$APP"
else
  # 增量构建更新共享 Localization.bundle 时，Xcode 可能保留 Widget 的旧资源封印。
  # 从内到外重签 Widget，保留 Xcode 已展开的 profile entitlement，再重签主应用。
  if [ "$MODE" = network-component ]; then
    codesign --force --sign "$IDENTITY" "${STAMP[@]}" --preserve-metadata=identifier,entitlements,flags "$SYSTEM_EXTENSION"
  else
    codesign --force --sign "$IDENTITY" "${STAMP[@]}" --preserve-metadata=identifier,entitlements,flags "$APP/Contents/PlugIns/XStatsWidget.appex"
  fi
  codesign --force --sign "$IDENTITY" "${STAMP[@]}" --preserve-metadata=identifier,entitlements,flags "$APP"
fi
codesign --verify --deep --strict "$APP"
