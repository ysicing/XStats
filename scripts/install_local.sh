#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# 替换固定安装路径，定向修复 Widget 登记；保留桌面配置及其他位置的构建。
# 用移动而不是复制，所选编译目录里不留第二份；不修改签名或重启通知中心。
#
#   scripts/install_local.sh build/DerivedData-arm64/Build/Products/Release/XStats.app
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${1:?用法：scripts/install_local.sh <XStats.app>}"
TARGET="/Applications/XStats.app"
BUNDLE_ID="work.12306.xstats.app"
WIDGET_ID="${BUNDLE_ID}.widget"
WIDGET_SUFFIX="/Contents/PlugIns/XStatsWidget.appex"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$SOURCE" ] || { echo "error: 找不到 $SOURCE" >&2; exit 1; }
SOURCE="$(cd "$SOURCE" && pwd -P)"
[ "$SOURCE" != "$TARGET" ] && [ ! "$SOURCE" -ef "$TARGET" ] && [ ! -L "$TARGET" ] || {
  echo "error: 安装源不能是目标应用，目标路径也不能是符号链接" >&2
  exit 1
}
case "$SOURCE/" in
  "$TARGET/"*) echo "error: 安装源不能位于目标应用内部" >&2; exit 1 ;;
esac
codesign --verify --deep --strict "$SOURCE"

# 在退出旧应用前核对身份，避免把独立预览产品覆盖到正式安装路径。
python3 - "$SOURCE" "$BUNDLE_ID" "$WIDGET_ID" "$WIDGET_SUFFIX" <<'PY'
from pathlib import Path
import plistlib
import sys

source, app_id, widget_id, suffix = sys.argv[1:]
try:
    app = plistlib.loads((Path(source) / "Contents/Info.plist").read_bytes())
    widget = plistlib.loads(Path(source + suffix + "/Contents/Info.plist").read_bytes())
    if (app.get("CFBundleIdentifier") != app_id
            or widget.get("CFBundleIdentifier") != widget_id
            or widget.get("NSExtension", {}).get("NSExtensionPointIdentifier")
            != "com.apple.widgetkit-extension"):
        raise ValueError("应用或 Widget 标识不匹配")
except (OSError, ValueError, TypeError, AttributeError) as error:
    sys.exit(f"error: 无效的安装源：{error}")
PY

# 保存登记快照用于排障；不读取、写入或备份受系统保护的桌面布局数据库。
REGISTRATION_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/xstats-install.XXXXXX")"
echo "Widget 登记快照：$REGISTRATION_DIR"

read_widget_registration() {
  local snapshot="$1"
  if ! pluginkit -m -A -D -vvv -i "$WIDGET_ID" >"$snapshot" 2>"$snapshot.stderr" \
      || [ -s "$snapshot.stderr" ]; then
    cat "$snapshot.stderr" >&2
    echo "error: 无法读取 Widget 登记，停止安装；快照：$REGISTRATION_DIR" >&2
    return 1
  fi
  # --raw 在部分系统上返回 XPC 描述而非 plist，解析带字段名的详细列表。
  python3 - "$snapshot" "$WIDGET_ID" "$WIDGET_SUFFIX" >"$snapshot.paths" <<'PY'
from pathlib import Path
import re
import sys

snapshot, identifier, suffix = sys.argv[1:]
text = Path(snapshot).read_text()
records = []
path = None
try:
    for line in text.splitlines():
        field = re.fullmatch(r"\s*(Path|Parent Bundle) = (.+)", line)
        if not field:
            continue
        key, value = field.groups()
        if key == "Path":
            if path is not None:
                raise ValueError("扩展登记缺少父应用")
            path = value
        else:
            if (path is None or not path.endswith(suffix)
                    or path[:-len(suffix)] != value or not value.endswith(".app")
                    or not Path(value).is_absolute() or "\t" in path
                    or ".." in Path(value).parts):
                raise ValueError("扩展路径或父应用不匹配")
            records.append((path, value))
            path = None
    headers = re.findall(r"^\s*[+!=?\-]?\s*" + re.escape(identifier) + r"\([^\n]+\)",
                         text, re.MULTILINE)
    count = re.search(r"^\s*\((\d+) plug-ins?\)\s*$", text, re.MULTILINE)
    if (path is not None or len(headers) != len(records)
            or (count and int(count[1]) != len(records))
            or (text.strip() and not records and (not count or count[1] != "0"))):
        raise ValueError("无法确认 Widget 登记列表完整性")
except ValueError as error:
    sys.exit(f"error: {error}；登记快照：{snapshot}")
for path, parent in records:
    print(path + "\t" + parent)
PY
}

read_widget_registration "$REGISTRATION_DIR/before.txt"

# 旧扩展可能在主应用退出后继续运行，必须在替换包之前结束。
# 按完整可执行路径匹配，避免终止其他工作区的同名应用或扩展。
python3 - "$SOURCE" "$TARGET" <<'PY' >"$REGISTRATION_DIR/process-patterns.txt"
import re
import sys

for app in [*sys.argv[1:], "/Applications/OpenStats.app"]:
    for executable in ["/Contents/MacOS/XStats",
                       "/Contents/PlugIns/XStatsWidget.appex/Contents/MacOS/XStatsWidget"]:
        print("^" + re.escape(app + executable) + "([[:space:]]|$)")
print("^" + re.escape("/Applications/OpenStats.app/Contents/MacOS/OpenStats") + "([[:space:]]|$)")
PY
while IFS= read -r pattern; do
  if pgrep -f "$pattern" >/dev/null; then
    pkill -f "$pattern" 2>/dev/null || true
    for _ in $(seq 1 25); do pgrep -f "$pattern" >/dev/null || break; sleep 0.2; done
    if pgrep -f "$pattern" >/dev/null; then
      echo "error: 目标应用或 Widget 尚未退出，请退出后重新安装" >&2
      exit 1
    fi
  fi
done <"$REGISTRATION_DIR/process-patterns.txt"

# 即使父应用已改名或文件已删除，也按 Widget 登记中的确切路径注销。
# 其他工作区只取消登记并提示，绝不删除、移动或重新签名其构建。
LEGACY_UNREGISTERED=0
while IFS=$'\t' read -r widget parent; do
  if [ "$parent" != "$TARGET" ] && [ "$parent" != "$SOURCE" ]; then
    echo "提示：取消旧 Widget 登记，保留文件（仍可能被系统重新发现）：$parent"
  fi
  if ! pluginkit -r "$widget" || ! "$LSREGISTER" -u "$parent"; then
    echo "error: 无法注销旧 Widget 或父应用，停止替换应用；登记快照：$REGISTRATION_DIR" >&2
    exit 1
  fi
  if [ "$parent" = /Applications/OpenStats.app ]; then
    LEGACY_UNREGISTERED=1
  fi
done <"$REGISTRATION_DIR/before.txt.paths"

# 仅移除旧应用包；旧偏好、日志与历史数据库不迁移，也不删除。
if [ -d /Applications/OpenStats.app ]; then
  if [ "$LEGACY_UNREGISTERED" -eq 0 ]; then
    "$LSREGISTER" -u /Applications/OpenStats.app
  fi
  rm -rf /Applications/OpenStats.app
fi

if [ -d "$TARGET" ]; then
  # 已在登记循环中注销；重复注销可能返回 -10814 并中断替换。
  rm -rf "$TARGET"
fi
mv "$SOURCE" "$TARGET"
if ! "$LSREGISTER" -f "$TARGET" || ! pluginkit -a "$TARGET$WIDGET_SUFFIX"; then
  echo "error: 应用已替换，但主应用或 Widget 登记失败；保留现有配置，登记快照：$REGISTRATION_DIR" >&2
  exit 1
fi

# 只接受正式安装这一条记录，避免登记失败后仍输出“安装成功”。
read_widget_registration "$REGISTRATION_DIR/after.txt"
expected="$(printf '%s\t%s' "$TARGET$WIDGET_SUFFIX" "$TARGET")"
if [ "$(cat "$REGISTRATION_DIR/after.txt.paths")" != "$expected" ]; then
  cat "$REGISTRATION_DIR/after.txt" >&2
  echo "error: Widget 登记未收敛到正式安装；应用已替换，保留全部配置和其他构建，请检查快照：$REGISTRATION_DIR" >&2
  exit 1
fi

open "$TARGET"
version="$(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString) ($(defaults read "$TARGET/Contents/Info" CFBundleVersion))"
echo "✅ 已安装并启动 XStats ${version}：${TARGET}"
