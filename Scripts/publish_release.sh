#!/bin/bash
# 把已公证的 Apple Silicon DMG 与在线升级包上传到对象存储，建 GitHub Release（手动下载入口），
# 最后把版本清单提交给版本 API（已安装的应用据此提示升级），cask 提交到 homebrew tap。
#
#   ./Scripts/release.sh          # 先打包、公证
#   git commit && git push        # 再提交并推送版本改动
#   ./Scripts/publish_release.sh  # 最后发布
set -euo pipefail
cd "$(dirname "$0")/.."

TAP="${TAP:-gentpan/homebrew-tap}"
MC_TARGET="${MC_TARGET:-cos/oss/apps/macOS/XStats}"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://c.ysicing.net/oss/apps/macOS/XStats}"
VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml | head -1)"
APPCAST="dist/appcast.json"
CASK="dist/xstats.rb"

# gh release 会在远端默认分支的 HEAD 上打 tag。版本改动没推送的话，v${VERSION} 会指向
# 一个不含该版本的提交。这里只读校验，不替调用者 commit 或 push。
RELEASE_FILES=(project.yml CHANGELOG.md README.md README.en.md README.ja.md README.ko.md)
git diff --quiet -- "${RELEASE_FILES[@]}" \
  || { echo "有未提交的发布文件改动，请先提交并推送" >&2; exit 1; }
git diff --cached --quiet -- "${RELEASE_FILES[@]}" \
  || { echo "暂存区还有未提交的发布文件，请先提交并推送" >&2; exit 1; }
git fetch --quiet origin main
HEAD_SHA="$(git rev-parse HEAD)"
[ "$HEAD_SHA" = "$(git rev-parse origin/main)" ] \
  || { echo "HEAD 与 origin/main 不一致，请先推送版本改动" >&2; exit 1; }
grep -q "^## ${VERSION} · " CHANGELOG.md \
  || { echo "CHANGELOG.md 顶部不是 ${VERSION}，与 project.yml 不一致" >&2; exit 1; }

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

# 上传后从 CDN 回读比对：安装包文件名带版本号、内容不可变，长 TTL 缓存无副作用；
# 若此前有人探测过同名 URL 留下 404 负缓存，刷新该路径后重跑即可。
upload() {
  local name online
  name="$(basename "$1")"
  mc cp --quiet "$1" "$MC_TARGET/${name}"
  online="$(curl -fsSL --max-time 300 "${DOWNLOAD_BASE}/${name}" | shasum -a 256 | cut -d' ' -f1)"
  [ "$online" = "$(shasum -a 256 "$1" | cut -d' ' -f1)" ] \
    || { echo "线上 ${name} 校验不一致：$online" >&2; exit 1; }
  echo "✅ ${DOWNLOAD_BASE}/${name}"
}
upload "dist/XStats-${VERSION}-AppleSilicon.dmg"
upload "dist/XStats-${VERSION}-AppleSilicon.zip"

# GitHub Release 是手动下载入口：应用内“手动下载”在没拿到清单时会跳到 releases/latest，
# 那里必须挂着 dmg。整段必须可安全重跑。
# 不能用 trap 清理：脚本后面的 Homebrew tap 段会再设一个 EXIT trap，把这个覆盖掉。
# 用完立刻删；中途失败最多留下一个临时小文件。
NOTES="$(mktemp)"
# 取 CHANGELOG 里该版本段落的原文，而不是 appcast 里截断到 48 字的摘要
awk -v v="## ${VERSION} · " '
  index($0, v) == 1 { inside = 1; next }
  inside && /^## / { exit }
  inside { print }
' CHANGELOG.md > "$NOTES"
[ -s "$NOTES" ] || { rm -f "$NOTES"; echo "CHANGELOG.md 里没有 ${VERSION} 的正文" >&2; exit 1; }
DMG="dist/XStats-${VERSION}-AppleSilicon.dmg"
if gh release view "v${VERSION}" >/dev/null 2>&1; then
  # 重跑：远端 tag 必须还指向这次发布的提交，不擅自移动已有的 tag。
  # 用 git ls-remote 读实际 ref，而不是 release 的 targetCommitish——后者可能是分支名。
  TAGGED="$(git ls-remote origin "refs/tags/v${VERSION}" | cut -f1)"
  [ "$TAGGED" = "$HEAD_SHA" ] \
    || { rm -f "$NOTES"; echo "v${VERSION} 已存在且指向 ${TAGGED:-未知}，与当前 HEAD 不一致" >&2; exit 1; }
  gh release upload "v${VERSION}" "$DMG" --clobber
else
  gh release create "v${VERSION}" "$DMG" --target "$HEAD_SHA" --title "v${VERSION}" --notes-file "$NOTES"
fi
gh release edit "v${VERSION}" --notes-file "$NOTES"
rm -f "$NOTES"
echo "✅ https://github.com/ysicing/xstats/releases/tag/v${VERSION}"

# 清单最后提交：安装包已在对象存储就位并校验通过后，已安装的应用才会看到新版本。
# Token 只从环境变量读取，不出现在命令参数里。
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
