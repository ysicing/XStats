#!/bin/bash
# 发布一个可分发的 Apple Silicon 版本：Developer ID 签名 → 公证 → 装订 → DMG（签名、公证、装订）
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
APP="build/DerivedData-arm64/Build/Products/Release/XStats.app"

# 在线升级的更新摘要取自下一版本的更新日志：发版前把 “## 未发布” 改成 “## 版本 · 日期”
NEXT_VERSION="$(./Scripts/version.sh next)"
grep -q "^## ${NEXT_VERSION} · " CHANGELOG.md \
  || { echo "error: CHANGELOG.md 里没有 “## ${NEXT_VERSION} · 日期” 标题，先把 “## 未发布” 改成正式版本。" >&2; exit 1; }

if [ -z "$SIGN_ID" ]; then
  echo "error: 钥匙串里没有 Developer ID Application 证书，无法发布。" >&2
  exit 1
fi
TEAM_ID="$(echo "$SIGN_ID" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')"

# 发布前推进一次公开版本号和内部构建号
./Scripts/version.sh build >/dev/null
VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml | head -1)"
BUILD="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([0-9]+)"?.*/\1/p' project.yml | head -1)"
[ "$VERSION" = "$NEXT_VERSION" ] || { echo "error: 版本号生成结果不一致：${VERSION} != ${NEXT_VERSION}" >&2; exit 1; }
echo "版本 ${VERSION} · 签名身份：${SIGN_ID}"

notarize() {
  echo "提交公证：$(basename "$1")（通常需要几分钟）…"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$DIST"
mkdir -p "$DIST"

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
python3 Scripts/appcast.py "$VERSION" "$BUILD" "$DOWNLOAD_BASE" \
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

# 本机只保留一份：把发布版装到 /Applications
./Scripts/install_local.sh "$APP"

echo
echo "✅ ${DIST}/${NAME}.dmg  SHA-256 $(shasum -a 256 "$DIST/$NAME.dmg" | cut -d' ' -f1)"
echo "   在线升级：${DIST}/*.zip · ${DIST}/appcast.json"
echo "   Homebrew cask：${DIST}/xstats.rb"
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "⚠️  未公证，仅供本机测试。"
else
  echo "下一步：./Scripts/publish_release.sh 上传安装包到官网并更新 gentpan/homebrew-tap。"
fi
