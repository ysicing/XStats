#!/bin/bash
# 发布一个可分发的版本：Apple 芯片版与 Intel 版各自 Developer ID 签名 → 公证 → 装订 → DMG（签名、公证、装订）
# → 在线升级包 → 版本清单 → Homebrew cask。
#
#   ./Scripts/release.sh
#
# 需要钥匙串里的 Developer ID Application 证书和 notarytool 凭据。凭据按 Apple ID 与团队保存，
# 默认用 GiantAccel 开发者账号的 “GiantAccel” 凭据；也可以单独保存一份：
#   xcrun notarytool store-credentials XStats --apple-id you@example.com --team-id <TEAM_ID>
#   NOTARY_PROFILE=XStats ./Scripts/release.sh
#
# SKIP_NOTARIZE=1 只生成未公证的 DMG 供本机测试——不要分发，别的 Mac 上 Gatekeeper 会拒绝打开。
set -euo pipefail
cd "$(dirname "$0")/.."

# 安装包放在官网
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://getopenstats.com/download}"
DIST="${DIST:-dist}"
NOTARY_PROFILE="${NOTARY_PROFILE:-GiantAccel}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)}"
VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml | head -1)"
# 编译架构与文件名里的芯片名：XStats-0.3.1-AppleSilicon.dmg、XStats-0.3.1-Intel.dmg
ARCHS=(arm64 x86_64)
chip() { [ "$1" = arm64 ] && echo AppleSilicon || echo Intel; }
app_for() { echo "build/DerivedData-$1/Build/Products/Release/XStats.app"; }

# 在线升级的更新摘要取自该版本的更新日志：发版前把 “## 未发布” 改成 “## 版本 · 日期”
grep -q "^## ${VERSION} · " CHANGELOG.md \
  || { echo "error: CHANGELOG.md 里没有 “## ${VERSION} · 日期” 标题，先把 “## 未发布” 改成正式版本。" >&2; exit 1; }

if [ -z "$SIGN_ID" ]; then
  echo "error: 钥匙串里没有 Developer ID Application 证书，无法发布。" >&2
  exit 1
fi
TEAM_ID="$(echo "$SIGN_ID" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')"
echo "版本 ${VERSION} · 签名身份：${SIGN_ID}"

notarize() {
  echo "提交公证：$(basename "$1")（通常需要几分钟）…"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$DIST"
mkdir -p "$DIST"

# 两种芯片共用一个构建号：先加一次，各自构建时不再加
./Scripts/version.sh build >/dev/null
BUILD="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([0-9]+)"?.*/\1/p' project.yml | head -1)"

for arch in "${ARCHS[@]}"; do
  APP="$(app_for "$arch")"
  NAME="XStats-${VERSION}-$(chip "$arch")"
  echo
  echo "==== $(chip "$arch")（${arch}）===="

  # ---- 构建 ------------------------------------------------------------------

  rm -rf "$APP"
  make build CONFIG=Release INSTALL=0 BUMP=0 ARCH="$arch" SIGN_ID="$SIGN_ID"

  for binary in "$APP/Contents/MacOS/XStats" "$APP/Contents/MacOS/XStatsHelper" \
                "$APP/Contents/PlugIns/XStatsWidget.appex/Contents/MacOS/XStatsWidget"; do
    [ "$(lipo -archs "$binary")" = "$arch" ] \
      || { echo "error: $binary 的架构是 $(lipo -archs "$binary")，应当只有 $arch" >&2; exit 1; }
  done
  codesign --verify --deep --strict --verbose=2 "$APP"
  for binary in "$APP" "$APP/Contents/MacOS/XStatsHelper" "$APP/Contents/PlugIns/XStatsWidget.appex"; do
    details="$(codesign -dvv "$binary" 2>&1)"
    echo "$details" | grep -q "TeamIdentifier=${TEAM_ID}" \
      || { echo "error: $binary 未使用团队 ${TEAM_ID} 签名" >&2; exit 1; }
    echo "$details" | grep -q "Timestamp=" \
      || { echo "error: $binary 缺少安全时间戳" >&2; exit 1; }
    echo "$details" | grep -Eq "flags=.*runtime" \
      || { echo "error: $binary 未启用 Hardened Runtime" >&2; exit 1; }
  done

  # ---- 公证 App --------------------------------------------------------------

  if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    # ditto 而不是 zip：保留包内的符号链接与扩展属性
    ditto -c -k --keepParent "$APP" "$WORK/$NAME-notarize.zip"
    notarize "$WORK/$NAME-notarize.zip"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    # 拒绝发布 Gatekeeper 在用户机器上仍会拒绝的包（Intel 版的签名与公证票据同样能在本机校验）
    if ! spctl -a -vv "$APP" 2>&1 | grep -q accepted; then
      echo "error: Gatekeeper 仍然拒绝该 App，停止发布。" >&2
      spctl -a -vv "$APP" || true
      exit 1
    fi
  fi

  # ---- DMG -------------------------------------------------------------------

  rm -rf "$WORK/dmg"
  mkdir -p "$WORK/dmg"
  ditto "$APP" "$WORK/dmg/XStats.app"
  ln -s /Applications "$WORK/dmg/Applications"
  hdiutil create -volname "XStats ${VERSION}" -srcfolder "$WORK/dmg" -ov -format UDZO "$DIST/$NAME.dmg" >/dev/null
  codesign --force --timestamp --sign "$SIGN_ID" "$DIST/$NAME.dmg"

  if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    notarize "$DIST/$NAME.dmg"
    xcrun stapler staple "$DIST/$NAME.dmg"
    spctl -a -t open --context context:primary-signature -vv "$DIST/$NAME.dmg"
  fi

  # ---- 在线升级 ----------------------------------------------------------------

  # 应用内升级下载已装订票据的 .app 压缩包
  ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"
done

# 版本清单：顶层是 Apple 芯片版（0.3.0 只认顶层字段），intel 字段是 Intel 版
python3 Scripts/appcast.py "$VERSION" "$BUILD" "$DOWNLOAD_BASE" \
  "$DIST/XStats-${VERSION}-AppleSilicon.zip" "$DIST/XStats-${VERSION}-AppleSilicon.dmg" \
  "$DIST/XStats-${VERSION}-Intel.zip" "$DIST/XStats-${VERSION}-Intel.dmg" > "$DIST/appcast.json"

# ---- Homebrew cask ------------------------------------------------------------

SHA_ARM="$(shasum -a 256 "$DIST/XStats-${VERSION}-AppleSilicon.dmg" | cut -d' ' -f1)"
SHA_INTEL="$(shasum -a 256 "$DIST/XStats-${VERSION}-Intel.dmg" | cut -d' ' -f1)"
cat > "$DIST/xstats.rb" <<CASK
cask "xstats" do
  arch arm: "AppleSilicon", intel: "Intel"

  version "${VERSION}"
  sha256 arm:   "${SHA_ARM}",
         intel: "${SHA_INTEL}"

  url "${DOWNLOAD_BASE}/XStats-#{version}-#{arch}.dmg"
  name "XStats"
  desc "Menu bar system monitor with fan control, keep-awake and cleanup"
  homepage "https://github.com/ysicing/xstats"

  # 应用内置在线升级，brew upgrade 默认不再重复升级
  auto_updates true
  depends_on macos: :sonoma

  app "XStats.app"

  zap trash: [
    "~/Library/Logs/XStats",
    "~/Library/Preferences/work.12306.xstats.app.plist",
  ]
end
CASK

# 本机只保留一份：把本机芯片的发布版装到 /Applications，另一种芯片的编译产物由安装脚本一并清掉
native="$(uname -m)"
./Scripts/install_local.sh "$(app_for "$native")"

echo
for arch in "${ARCHS[@]}"; do
  NAME="XStats-${VERSION}-$(chip "$arch")"
  echo "✅ ${DIST}/${NAME}.dmg  SHA-256 $(shasum -a 256 "$DIST/$NAME.dmg" | cut -d' ' -f1)"
done
echo "   在线升级：${DIST}/*.zip · ${DIST}/appcast.json"
echo "   Homebrew cask：${DIST}/xstats.rb"
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "⚠️  未公证，仅供本机测试。"
else
  echo "下一步：./Scripts/publish_release.sh 上传安装包到官网并更新 gentpan/homebrew-tap。"
fi
