# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later
# 发布脚本共用的对象存储查询，由调用方 source。

# 存储查询失败不能当成“版本不存在”，否则断网或权限错误可能导致覆盖。
object_exists() {
  local stat
  stat="$(mktemp)"
  if mc stat --json "$1" > "$stat" 2>/dev/null; then rm -f "$stat"; return 0; fi
  if python3 - "$stat" <<'PYSTAT'
import json,sys
try:
    data=json.load(open(sys.argv[1]))
    missing=data.get('status')=='error' and data.get('error',{}).get('cause',{}).get('message')=='Object does not exist'
except (ValueError,OSError):
    missing=False
raise SystemExit(0 if missing else 1)
PYSTAT
  then rm -f "$stat"; return 1; fi
  rm -f "$stat"
  echo 'error: 无法确认源站版本包状态，停止发布' >&2
  exit 1
}
