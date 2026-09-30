#!/bin/bash
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

APP="$1"
IDENTITY="${2:--}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$FRAMEWORK" ] || { echo "error: 应用未嵌入 Sparkle.framework" >&2; exit 1; }
STAMP=(--timestamp)
OPTIONS=(--options runtime)
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  IDENTITY="-"
  STAMP=(--timestamp=none)
  OPTIONS=(--options 0)
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
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  codesign --force --sign - --timestamp=none --options 0 "$APP/Contents/MacOS/XStatsHelper"
  codesign --force --sign - --timestamp=none --options 0 --entitlements "$ROOT/Widget/XStatsWidget.entitlements" "$APP/Contents/PlugIns/XStatsWidget.appex"
  codesign --force --sign - --timestamp=none --options 0 --entitlements "$ROOT/App/XStats.entitlements" "$APP"
else
  codesign --force --sign "$IDENTITY" "${STAMP[@]}" --preserve-metadata=identifier,entitlements,flags "$APP"
fi
codesign --verify --deep --strict "$APP"
