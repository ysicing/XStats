#!/bin/bash
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail
cd "$(dirname "$0")/.."

compile="$(task --dry compile SIGN_ID= 2>&1)"
grep -q -- "-destination 'generic/platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO" <<< "$compile"
if grep -q 'x86_64' <<< "$compile"; then
  echo "默认构建不应包含 x86_64" >&2
  exit 1
fi
if grep -q -- '^  -quiet' <<< "$compile"; then
  echo "默认构建不应使用会产生 SwiftCompile 伪错误的 -quiet" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf 'zip' > "$WORK/XStats-0.6.1-AppleSilicon.zip"
printf 'dmg' > "$WORK/XStats-0.6.1-AppleSilicon.dmg"
python3 Scripts/appcast.py 0.6.1 1 https://example.test \
  "$WORK/XStats-0.6.1-AppleSilicon.zip" "$WORK/XStats-0.6.1-AppleSilicon.dmg" > "$WORK/appcast.json"
python3 - "$WORK/appcast.json" <<'PY'
import json
import sys

feed = json.load(open(sys.argv[1], encoding="utf-8"))
assert "intel" not in feed, feed
assert feed["url"].endswith("-AppleSilicon.zip"), feed
assert feed["dmg"].endswith("-AppleSilicon.dmg"), feed
PY
