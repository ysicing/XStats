#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# 独立网络组件：构建、签名、公证和ZIP/XML；仅 --publish 上传其独立对象存储前缀。
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=0
PUBLISH_ONLY=0
NOTES="${NETWORK_RELEASE_NOTES:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1; shift ;;
    --publish-only) PUBLISH=1; PUBLISH_ONLY=1; shift ;;
    --notes) [ "$#" -ge 2 ] || { echo 'error: --notes 缺少 JSON 路径' >&2; exit 1; }; NOTES="$2"; shift 2 ;;
    --help) echo '用法：release_network_component.sh --notes <组件摘要JSON> [--publish | --publish-only]'; exit 0 ;;
    *) echo "error: 未知参数：$1" >&2; exit 1 ;;
  esac
done

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/ { print $2; exit }' || true)}"
[ -n "$SIGN_ID" ] && [ "$SIGN_ID" != - ] \
  || { echo 'error: 独立组件发行需要有效 Developer ID Application 证书；ad-hoc 仅使用 task build-network-component' >&2; exit 1; }
[ -n "${XSTATS_COMPONENT_PROFILE:-}" ] \
  || { echo 'error: 需要 XSTATS_COMPONENT_PROFILE 选择网络组件的 Developer ID profile' >&2; exit 1; }
[ -n "${XSTATS_NETWORK_PROFILE:-}" ] \
  || { echo 'error: 需要 XSTATS_NETWORK_PROFILE 选择网络扩展的 Developer ID profile' >&2; exit 1; }
if [ "$PUBLISH" = 1 ] && [ "${SKIP_NOTARIZE:-0}" = 1 ]; then
  echo 'error: 未公证的组件不能发布' >&2
  exit 1
fi
[ -n "$NOTES" ] && [ -f "$NOTES" ] \
  || { echo 'error: --notes 或 NETWORK_RELEASE_NOTES 必须指定独立组件的中英文摘要 JSON' >&2; exit 1; }
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"
TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$SIGN_ID" | head -1 | sed -nE 's/.*\(([A-Z0-9]+)\)"$/\1/p' || true)"
[ -n "$TEAM_ID" ] || { echo 'error: 无法从 Developer ID 签名身份解析团队 ID' >&2; exit 1; }
VERSION="$(sed -nE 's/^ *NETWORK_EXTENSION_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml | head -1)"
BUILD="$(sed -nE 's/^ *NETWORK_EXTENSION_BUILD: *"?([0-9]+)"?.*/\1/p' project.yml | head -1)"
[ -n "$VERSION" ] && [ -n "$BUILD" ] || { echo 'error: 独立组件版本未配置' >&2; exit 1; }
python3 - "$NOTES" "$VERSION" <<'PY'
import json, sys
sys.path.insert(0, 'scripts')
from sparkle_appcast import load_localized_notes
from pathlib import Path
source = json.loads(Path(sys.argv[1]).read_text())
notes = source.get('sourceNotes')
if not isinstance(notes, list) or not notes or not all(isinstance(note, str) and note.strip() and '\n' not in note and '\r' not in note for note in notes):
    raise SystemExit('error: 组件中文摘要必须为非空的单行字符串列表')
load_localized_notes({'version': sys.argv[2], 'notes': notes}, Path(sys.argv[1]))
PY

APP="build/DerivedData-network-arm64/Build/Products/Release/XStats Network Monitor.app"
DIST="${NETWORK_DIST:-dist/network-monitor}"
BASE="https://c.ysicing.net/oss/apps/macOS/XStats/network-monitor"
TARGET="c-ip/oss/apps/macOS/XStats/network-monitor"
NOTARY_PROFILE="${NOTARY_PROFILE:-XStats}"
NAME="XStats-Network-Monitor-${VERSION}-AppleSilicon"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DIST"

# 存储查询失败不能当成“版本不存在”，否则断网或权限错误可能导致覆盖。
object_exists() {
  if mc stat --json "$1" > "$WORK/object-stat.json" 2>/dev/null; then return 0; fi
  if python3 - "$WORK/object-stat.json" <<'PYSTAT'
import json,sys
try:
    data=json.load(open(sys.argv[1]))
    missing=data.get('status')=='error' and data.get('error',{}).get('cause',{}).get('message')=='Object does not exist'
except (ValueError,OSError):
    missing=False
raise SystemExit(0 if missing else 1)
PYSTAT
  then return 1; fi
  echo 'error: 无法确认源站版本包状态，停止发布' >&2
  exit 1
}

if [ "$PUBLISH" = 1 ]; then
  XSTATS_APP_ID=xstats-network-monitor python3 scripts/publish_api.py --check-sparkle
fi

# 已发布公开版本不可重新构建覆盖；恢复只使用已公证的原始制品。
if [ "$PUBLISH" = 1 ] && [ "$PUBLISH_ONLY" = 0 ] && object_exists "$TARGET/$NAME.zip"; then
  echo 'error: 该组件公开版本已经存在，请用 --publish-only 复用原制品；代码变化须推进公开版本' >&2
  exit 1
fi
if [ "$PUBLISH_ONLY" = 0 ]; then
# 独立构建不会执行主版本 bump，也不安装或替换正在运行的应用。
task compile-network-component CONFIG=Release SIGN_ID="$SIGN_ID"
EXTENSION="$APP/Contents/Library/SystemExtensions/work.12306.xstats.app.networkextension.systemextension"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
[ -d "$EXTENSION" ] || { echo 'error: 独立组件缺少网络扩展' >&2; exit 1; }
[ ! -e "$APP/Contents/PlugIns/XStatsWidget.appex" ] && [ ! -e "$APP/Contents/MacOS/XStatsHelper" ] \
  || { echo 'error: 独立组件不得携带主应用 Widget 或 helper' >&2; exit 1; }
python3 - "$APP" "$TEAM_ID" <<'PY'
import pathlib, plistlib, sys
app=pathlib.Path(sys.argv[1]); info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
service=sys.argv[2]+'.work.12306.xstats.network-observation.control'
if info.get('NetworkObservationProtocolVersion')!=2 or info.get('NetworkObservationControlMachService')!=service:
    raise SystemExit('error: 独立组件协议 2/control Mach service 不正确')
file=app/'Contents/Library/LaunchAgents/work.12306.xstats.networkmonitor.agent.plist'
if not file.is_file():
    raise SystemExit('error: 独立组件缺少按需 LaunchAgent')
agent=plistlib.loads(file.read_bytes())
if (agent.get('Label')!='work.12306.xstats.networkmonitor.agent'
    or agent.get('BundleProgram')!='Contents/MacOS/XStats Network Monitor'
    or agent.get('ProgramArguments')!=['XStats Network Monitor','--service']
    or agent.get('MachServices')!={service:True}
    or 'RunAtLoad' in agent or 'KeepAlive' in agent):
    raise SystemExit('error: 独立组件 LaunchAgent 不是按需控制服务')
PY
for binary in "$APP/Contents/MacOS/XStats Network Monitor" \
              "$EXTENSION/Contents/MacOS/work.12306.xstats.app.networkextension" \
              "$FRAMEWORK/Sparkle" "$FRAMEWORK/Autoupdate" \
              "$FRAMEWORK/Updater.app/Contents/MacOS/Updater" \
              "$FRAMEWORK/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
              "$FRAMEWORK/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"; do
  [ "$(lipo -archs "$binary")" = arm64 ] || { echo "error: $binary 不是单一 arm64 架构" >&2; exit 1; }
done
codesign --verify --deep --strict --verbose=2 "$APP"
for binary in "$APP" "$EXTENSION" "$APP/Contents/Frameworks/Sparkle.framework" \
              "$FRAMEWORK/Autoupdate" "$FRAMEWORK/Updater.app" \
              "$FRAMEWORK/XPCServices/Installer.xpc" "$FRAMEWORK/XPCServices/Downloader.xpc"; do
  details="$(codesign -dvv "$binary" 2>&1)"
  echo "$details" | grep -q "TeamIdentifier=${TEAM_ID}" || { echo "error: $binary 签名团队不一致" >&2; exit 1; }
  echo "$details" | grep -q 'Timestamp=' || { echo "error: $binary 缺少安全时间戳" >&2; exit 1; }
  echo "$details" | grep -Eq 'flags=.*runtime' || { echo "error: $binary 缺少 Hardened Runtime" >&2; exit 1; }
done
codesign -d --entitlements :- "$APP" 2>/dev/null | python3 -c '
import plistlib, sys
entitlements = plistlib.loads(sys.stdin.buffer.read())
if not entitlements.get("com.apple.developer.system-extension.install"):
    raise SystemExit("error: 组件缺少系统扩展安装权限")
if "content-filter-provider-systemextension" not in entitlements.get("com.apple.developer.networking.networkextension", []):
    raise SystemExit("error: 组件缺少 Network Extension 权限")
'

if [ "${SKIP_NOTARIZE:-0}" != 1 ]; then
  ditto -c -k --norsrc --keepParent "$APP" "$WORK/notarize.zip"
  xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl -a -vv "$APP" 2>&1 | grep -q accepted \
    || { echo 'error: Gatekeeper 拒绝独立组件' >&2; exit 1; }
fi

ditto -c -k --norsrc --keepParent "$APP" "$DIST/$NAME.zip"
# 首次安装器只接受单根 app；直接验证最终 ZIP 展开后的签名与普通文件里的公证 ticket。
PROBE="$WORK/archive-probe"
mkdir -p "$PROBE"
ditto -x -k "$DIST/$NAME.zip" "$PROBE"
PROBE_APP="$PROBE/XStats Network Monitor.app"
[ -d "$PROBE_APP" ] && [ ! -e "$PROBE/__MACOSX" ] \
  || { echo 'error: 最终 ZIP 不符合单根应用安装契约' >&2; exit 1; }
codesign --verify --deep --strict "$PROBE_APP"
if [ "${SKIP_NOTARIZE:-0}" != 1 ]; then xcrun stapler validate "$PROBE_APP"; fi
python3 - "$VERSION" "$BUILD" "$BASE" "$DIST/$NAME.zip" "$APP" "$NOTES" > "$DIST/appcast.json" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, 'scripts')
from appcast import component_manifest
feed = component_manifest(sys.argv[1], sys.argv[2], sys.argv[3], Path(sys.argv[4]), Path(sys.argv[5]), Path(sys.argv[6]))
json.dump(feed, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write('\n')
PY
python3 scripts/sparkle_appcast.py "$DIST/appcast.json" "$DIST/$NAME.zip" \
  --notes-file "$NOTES" --app-info "$APP/Contents/Info.plist" --output "$DIST/appcast.xml"

else
  for file in "$DIST/$NAME.zip" "$DIST/appcast.json" "$DIST/appcast.xml"; do
    [ -f "$file" ] || { echo "error: 缺少已有发行制品 $file" >&2; exit 1; }
  done
  python3 - "$DIST/appcast.json" "$VERSION" "$BUILD" "$BASE/$NAME.zip" <<'PYVERIFY'
import json, sys
feed=json.load(open(sys.argv[1]))
if (feed.get('version'),feed.get('build'),feed.get('url')) != tuple(sys.argv[2:]):
    raise SystemExit('error: 既有制品的版本、构建号或地址与当前声明不一致')
PYVERIFY
  python3 scripts/sparkle_appcast.py "$DIST/appcast.json" "$DIST/$NAME.zip" --verify \
    --notes-file "$NOTES" --app-info "$APP/Contents/Info.plist" --output "$DIST/appcast.xml"
fi

if [ "$PUBLISH" = 1 ]; then
  # 首次安装与 Sparkle 共用一份版本包；先验证 ZIP，再切换更新清单。
  upload() {
    local file="$1" name="$2" cache="$3" actual expected
    expected="$(shasum -a 256 "$file" | cut -d' ' -f1)"
    if [[ "$cache" == *immutable* ]] && object_exists "$TARGET/$name"; then
      actual="$(mc cat "$TARGET/$name" | shasum -a 256 | cut -d' ' -f1)"
      [ "$actual" = "$expected" ] || { echo "error: 禁止覆盖组件版本包 $name" >&2; exit 1; }
    else
      mc cp --quiet --attr "Cache-Control=$cache" "$file" "$TARGET/$name"
    fi
    actual="$(curl -fsSL --max-time 300 "$BASE/$name?verify=$(date +%s)-$$" | shasum -a 256 | cut -d' ' -f1)"
    [ "$expected" = "$actual" ] || { echo "error: CDN $name 内容不一致" >&2; exit 1; }
  }
  upload "$DIST/$NAME.zip" "$NAME.zip" 'public,max-age=31536000,immutable'
  upload "$DIST/appcast.xml" "$NAME.xml" 'public,max-age=31536000,immutable'
  XSTATS_APP_ID=xstats-network-monitor python3 scripts/publish_api.py "$DIST/appcast.json"
  XSTATS_APP_ID=xstats-network-monitor python3 scripts/publish_api.py --check-sparkle
  XSTATS_APP_ID=xstats-network-monitor python3 scripts/publish_api.py --verify-sparkle "$DIST/appcast.xml"
  echo "已发布并验证：网络组件版本包与三个区域 API"
else
  echo "已生成：$DIST/$NAME.zip 和 $DIST/appcast.xml（未上传）"
fi
