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

# 预检不能阻止其他发布者抢先创建；单次条件 PUT 由服务端保证不覆盖。
object_upload_immutable() {
  local file="$1" target="$2" cache="${3:-}" response actual expected
  local options=(--disable-multipart --quiet --json)
  if [ -n "$cache" ]; then options+=(--attr "Cache-Control=$cache"); fi
  response="$(mktemp)" || return 1
  if mc --custom-header 'If-None-Match: *' cp "${options[@]}" "$file" "$target" > "$response" 2>/dev/null; then
    rm -f "$response"
    return 0
  fi
  # 只对明确的条件冲突回读；网络、权限和未知错误不能因对象可读而被吞掉。
  if ! python3 - "$response" <<'PYCONFLICT'
import json, sys
try:
    with open(sys.argv[1]) as source:
        text = source.read(256 * 1024 + 1)
    if len(text) > 256 * 1024:
        raise ValueError("response too large")
    events = [json.loads(line) for line in text.splitlines() if line.strip()]
    errors = [event for event in events if event.get("status") == "error"]
    conflict = len(errors) == 1 and errors[0]["error"]["cause"]["error"]["Code"] == "PreconditionFailed"
except (OSError, ValueError, KeyError, TypeError, AttributeError):
    conflict = False
raise SystemExit(0 if conflict else 1)
PYCONFLICT
  then
    rm -f "$response"
    echo 'error: 版本对象条件上传失败，停止发布' >&2
    return 1
  fi
  rm -f "$response"
  if ! actual="$(mc cat "$target" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"; then
    echo 'error: 无法校验并发创建的版本对象，停止发布' >&2
    return 1
  fi
  expected="$(shasum -a 256 "$file" | cut -d' ' -f1)" || return 1
  if [ "$actual" != "$expected" ]; then
    echo "error: 禁止覆盖已发布的 $(basename "$file")；构建变化须推进版本号" >&2
    return 1
  fi
}
