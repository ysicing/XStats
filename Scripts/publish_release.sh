#!/bin/bash
# 发布已公证的 Apple Silicon 版 DMG、在线升级包到官网 /download/，最后更新静态清单并提交版本 API（已安装的应用据此提示升级），
# cask 提交到 gentpan/homebrew-tap，并校验线上文件。
#
#   ./Scripts/release.sh          # 先打包、公证
#   ./Scripts/publish_release.sh  # 再发布
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${SITE_HOST:-debian@51.38.126.148}"
KEY="${SITE_KEY:-$HOME/.ssh/gentpan.pem}"
ROOT="${SITE_ROOT:-/var/www/getopenstats.com}"
TAP="${TAP:-gentpan/homebrew-tap}"
VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml | head -1)"
APPCAST="dist/appcast.json"
CASK="dist/xstats.rb"
SSH=(ssh -i "$KEY" -o BatchMode=yes "$HOST")

for ext in dmg zip; do
  file="dist/XStats-${VERSION}-AppleSilicon.${ext}"
  [ -f "$file" ] || { echo "缺少 $file，先运行 ./Scripts/release.sh" >&2; exit 1; }
done
for file in "$APPCAST" "$CASK"; do
  [ -f "$file" ] || { echo "缺少 $file，先运行 ./Scripts/release.sh" >&2; exit 1; }
done
python3 - "$APPCAST" "$VERSION" "dist/XStats-${VERSION}-AppleSilicon.zip" <<'PY' \
  || { echo "$APPCAST 与升级包不一致" >&2; exit 1; }
import hashlib, json, sys
feed = json.load(open(sys.argv[1]))
digest = lambda path: hashlib.sha256(open(path, "rb").read()).hexdigest()
assert feed["version"] == sys.argv[2] and feed["notes"], feed
assert feed["sha256"] == digest(sys.argv[3]) and feed["url"].endswith("-AppleSilicon.zip"), feed
assert "intel" not in feed, feed
PY
grep -q "version \"${VERSION}\"" "$CASK" || { echo "$CASK 的版本不是 ${VERSION}" >&2; exit 1; }
dmg="dist/XStats-${VERSION}-AppleSilicon.dmg"
xcrun stapler validate "$dmg" >/dev/null || { echo "$dmg 没有装订公证票据" >&2; exit 1; }
grep -q "$(shasum -a 256 "$dmg" | cut -d' ' -f1)" "$CASK" || { echo "$CASK 里的 sha256 与 $dmg 不一致" >&2; exit 1; }

# 上传：先传临时名再改名，下载中途不会拿到半个文件
"${SSH[@]}" "sudo install -d -o \$(id -un) -m 755 $ROOT/download"
upload() {
  local name
  name="$(basename "$1")"
  scp -i "$KEY" -o BatchMode=yes "$1" "$HOST:$ROOT/download/.${name}.part"
  "${SSH[@]}" "mv -f $ROOT/download/.${name}.part $ROOT/download/${name} && chmod 644 $ROOT/download/${name}"
  local online
  online="$(curl -fsSL --max-time 300 "https://getopenstats.com/download/${name}" | shasum -a 256 | cut -d' ' -f1)"
  [ "$online" = "$(shasum -a 256 "$1" | cut -d' ' -f1)" ] || { echo "线上 ${name} 校验不一致：$online" >&2; exit 1; }
  echo "✅ https://getopenstats.com/download/${name}"
}
upload "dist/XStats-${VERSION}-AppleSilicon.dmg"
upload "dist/XStats-${VERSION}-AppleSilicon.zip"
# 版本清单最后发布：安装包都已就位后，已安装的应用才会看到新版本
upload "$APPCAST"
# 新版客户端从 API 读取同一份清单；Token 只从环境变量读取，不出现在命令参数里。
python3 Scripts/publish_api.py "$APPCAST"

# Homebrew tap
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$TAP" "$WORK/tap" -- --quiet
mkdir -p "$WORK/tap/Casks"
cp "$CASK" "$WORK/tap/Casks/xstats.rb"
if git -C "$WORK/tap" diff --quiet -- Casks/xstats.rb && git -C "$WORK/tap" ls-files --error-unmatch Casks/xstats.rb >/dev/null 2>&1; then
  echo "✅ $TAP 已是 ${VERSION}"
else
  git -C "$WORK/tap" add Casks/xstats.rb
  git -C "$WORK/tap" commit -q -m "xstats ${VERSION}"
  git -C "$WORK/tap" push -q
  echo "✅ 已提交 Casks/xstats.rb 到 $TAP"
fi
echo "安装：brew install --cask gentpan/tap/xstats"
