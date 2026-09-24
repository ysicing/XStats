#!/bin/bash
# 发布一个可分发的 Apple Silicon 版本：Developer ID 签名 → 公证 → 装订 → DMG（签名、公证、装订）
# → 在线升级包 → 版本清单 → Homebrew cask。
#
#   ./scripts/release.sh
#
# 需要钥匙串里的 Developer ID Application 证书和 notarytool 凭据。凭据按 Apple ID 与团队保存，
# 默认使用 “XStats” 凭据；如尚未保存，可以执行：
#   xcrun notarytool store-credentials XStats --apple-id you@example.com --team-id <TEAM_ID>
#   NOTARY_PROFILE=XStats ./scripts/release.sh
#
# SKIP_NOTARIZE=1 只生成未公证的 DMG 供本机测试——不要分发，别的 Mac 上 Gatekeeper 会拒绝打开。
set -euo pipefail
cd "$(dirname "$0")/.."

# 安装包放在对象存储，由 scripts/publish_release.sh 用 mc 上传
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://c.ysicing.net/oss/apps/macOS/XStats}"
DIST="${DIST:-dist}"
NOTARY_PROFILE="${NOTARY_PROFILE:-XStats}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/Developer ID Application/ { print $2; exit }' || true)}"
APP="build/DerivedData-arm64/Build/Products/Release/XStats.app"

# 构建只允许版本元数据有未提交改动；Swift、脚本或其他源码必须来自当前 HEAD。
BASE_SHA="$(python3 scripts/release_provenance.py prepare)"

if [ -z "$SIGN_ID" ]; then
  echo "error: 钥匙串里没有 Developer ID Application 证书，无法发布。" >&2
  exit 1
fi
TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -F "$SIGN_ID" | head -1 | sed -nE 's/.*\(([A-Z0-9]+)\)"$/\1/p' || true)"

# 公开版本号取自 CHANGELOG.md 顶部的正式标题，同时推进一次内部构建号；
# 顶部还是 “## 未发布” 时脚本会在这里失败
VERSION="$(./scripts/version.sh release)"
BUILD="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([0-9]+)"?.*/\1/p' project.yml | head -1)"
echo "版本 ${VERSION} · 签名身份：${SIGN_ID}"

notarize() {
  echo "提交公证：$(basename "$1")（通常需要几分钟）…"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$DIST"
mkdir -p "$DIST"
PROVENANCE="$DIST/release-provenance.json"
python3 scripts/release_provenance.py record "$PROVENANCE" "$BASE_SHA" "$VERSION" "$BUILD"

NAME="XStats-${VERSION}-AppleSilicon"
echo
echo "==== Apple Silicon（arm64）===="

# ---- 构建 ------------------------------------------------------------------

rm -rf "$APP"
task build CONFIG=Release INSTALL=0 BUMP=0 SIGN_ID="$SIGN_ID"

for binary in "$APP/Contents/MacOS/XStats" "$APP/Contents/MacOS/XStatsHelper" \
              "$APP/Contents/PlugIns/XStatsWidget.appex/Contents/MacOS/XStatsWidget"; do
  [ "$(lipo -archs "$binary")" = arm64 ] \
    || { echo "error: $binary 的架构是 $(lipo -archs "$binary")，应当只有 arm64" >&2; exit 1; }
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

# 版本清单只包含 Apple Silicon 安装包
python3 scripts/appcast.py "$VERSION" "$BUILD" "$DOWNLOAD_BASE" \
  "$DIST/XStats-${VERSION}-AppleSilicon.zip" "$DIST/XStats-${VERSION}-AppleSilicon.dmg" > "$DIST/appcast.json"

# ---- Homebrew cask ------------------------------------------------------------

SHA_ARM="$(shasum -a 256 "$DIST/XStats-${VERSION}-AppleSilicon.dmg" | cut -d' ' -f1)"
cat > "$DIST/xstats.rb" <<CASK
cask "xstats" do
  version "${VERSION}"
  sha256 "${SHA_ARM}"

  url "${DOWNLOAD_BASE}/XStats-#{version}-AppleSilicon.dmg"
  name "XStats"
  desc "Menu bar system monitor with fan control, keep-awake and cleanup"
  homepage "https://github.com/ysicing/xstats"

  # 应用内置在线升级，brew upgrade 默认不再重复升级
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "XStats.app"

  zap trash: [
    "~/Library/Logs/XStats",
    "~/Library/Preferences/work.12306.xstats.app.plist",
  ]
end
CASK

# 发版只生成并校验制品，不替换或启动当前机器上的 XStats。
# 已公证的 App 留在 DerivedData，供发布前核验；本地安装需另行明确执行。

echo
echo "✅ ${DIST}/${NAME}.dmg  SHA-256 $(shasum -a 256 "$DIST/$NAME.dmg" | cut -d' ' -f1)"
echo "   在线升级：${DIST}/*.zip · ${DIST}/appcast.json"
echo "   Homebrew cask：${DIST}/xstats.rb"
echo "   本机已安装的 XStats 保持不变"
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "⚠️  未公证，仅供本机测试。"
else
  echo "下一步：提交并推送版本改动（project.yml、CHANGELOG.md、README 徽章），"
  echo "        再运行 ./scripts/publish_release.sh 上传安装包并发布。"
fi
