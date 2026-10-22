#!/bin/bash
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later
# 主程序发布脚本：已发布的同名安装包只允许内容一致的重跑，不得被重新构建的制品覆盖。
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" user.name fixture
git config --file "$GIT_CONFIG_GLOBAL" user.email fixture@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

mkdir -p "$WORK/repo/scripts" "$WORK/repo/dist" "$WORK/bin" "$WORK/objects"
cp scripts/publish_release.sh scripts/object_storage.sh "$WORK/repo/scripts/"
for stub in release_provenance sparkle_appcast; do
  echo 'pass' > "$WORK/repo/scripts/$stub.py"
done
cat > "$WORK/repo/scripts/publish_api.py" <<'PY'
import os, sys
open(os.environ['PUBLISH_TEST_LOG'], 'a').write('api ' + ' '.join(sys.argv[1:]) + '\n')
PY
cat > "$WORK/repo/scripts/sync_network_geography.py" <<'PY'
import os
open(os.environ['PUBLISH_TEST_LOG'], 'a').write('geography\n')
PY
echo 'print("notes")' > "$WORK/repo/scripts/github_release_notes.py"
cat > "$WORK/repo/project.yml" <<'YAML'
MARKETING_VERSION: "9.9.9"
CURRENT_PROJECT_VERSION: "999"
YAML
echo '## 9.9.9 · 2026-10-08' > "$WORK/repo/CHANGELOG.md"
printf 'dist/\n' > "$WORK/repo/.gitignore"

DIST="$WORK/repo/dist"
printf 'dmg fixture' > "$DIST/XStats-9.9.9-AppleSilicon.dmg"
printf 'zip fixture' > "$DIST/XStats-9.9.9-AppleSilicon.zip"
printf '<rss/>' > "$DIST/XStats-9.9.9-AppleSilicon.xml"
python3 - "$DIST" <<'PY'
import hashlib, json, pathlib, sys
dist = pathlib.Path(sys.argv[1])
digest = lambda name: hashlib.sha256((dist / name).read_bytes()).hexdigest()
(dist / 'appcast.json').write_text(json.dumps({
    'version': '9.9.9', 'build': '999', 'notes': ['fixture'], 'sha256': digest('XStats-9.9.9-AppleSilicon.zip'),
    'url': 'https://example.invalid/XStats-9.9.9-AppleSilicon.zip'}))
(dist / 'xstats.rb').write_text(f'version "9.9.9"\nsha256 "{digest("XStats-9.9.9-AppleSilicon.dmg")}"\n')
PY

git init -q --bare "$WORK/origin.git"
git -C "$WORK/repo" init -q
git -C "$WORK/repo" add -A
git -C "$WORK/repo" commit -q -m fixture
git -C "$WORK/repo" remote add origin "$WORK/origin.git"
git -C "$WORK/repo" push -q origin main
git init -q --bare "$WORK/tap.git"
git clone -q "$WORK/tap.git" "$WORK/tap-seed" 2>/dev/null
git -C "$WORK/tap-seed" commit -q --allow-empty -m seed
git -C "$WORK/tap-seed" push -q origin main

cat > "$WORK/bin/mc" <<'STUB'
#!/bin/bash
set -euo pipefail
name="${@: -1}"
name="${name##*/}"
conditional=0
if [ "$1" = --custom-header ]; then
  [ "$2" = 'If-None-Match: *' ] || exit 1
  conditional=1
  shift 2
fi
case "$1" in
  stat)
    if [ "${PUBLISH_STAT_ERROR:-0}" = 1 ]; then
      echo '{"status":"error","error":{"cause":{"message":"Access Denied"}}}'; exit 1
    fi
    if [ -f "$PUBLISH_TEST_OBJECTS/$name" ]; then echo '{"status":"success"}'; else
      echo '{"status":"error","error":{"cause":{"message":"Object does not exist"}}}'; exit 1
    fi ;;
  cat) cat "$PUBLISH_TEST_OBJECTS/$name" ;;
  cp)
    if [[ "$name" == *.zip ]] && [ -n "${PUBLISH_RACE:-}" ]; then
      if [ "$PUBLISH_RACE" = same ]; then
        cp "${@: -2:1}" "$PUBLISH_TEST_OBJECTS/$name"
      else
        printf 'concurrent release' > "$PUBLISH_TEST_OBJECTS/$name"
      fi
    fi
    if [ -n "${PUBLISH_UPLOAD_ERROR:-}" ] && [[ "$name" == *.zip ]]; then
      printf '{"status":"error","error":{"cause":{"error":{"Code":"%s"}}}}\n' "$PUBLISH_UPLOAD_ERROR"
      echo 'fixture-secret-must-not-leak' >&2
      exit 1
    fi
    if [ "$conditional" = 1 ]; then
      [[ " $* " == *" --disable-multipart "* ]] || exit 1
      if [ -f "$PUBLISH_TEST_OBJECTS/$name" ]; then
        echo '{"status":"success"}'
        echo '{"status":"error","error":{"cause":{"error":{"Code":"PreconditionFailed"}}}}'
        exit 1
      fi
    fi
    printf 'upload %s\n' "$name" >> "$PUBLISH_TEST_LOG"
    cp "${@: -2:1}" "$PUBLISH_TEST_OBJECTS/$name" ;;
  *) exit 1 ;;
esac
STUB
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
set -euo pipefail
name="${@: -1}"
name="${name##*/}"
printf 'verify %s\n' "$name" >> "$PUBLISH_TEST_LOG"
cat "$PUBLISH_TEST_OBJECTS/$name"
STUB
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$PUBLISH_TEST_LOG"
case "$1 $2" in
  'release view') exit 1 ;;
  'repo clone') git clone -q "$PUBLISH_TEST_TAP" "$4" ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/xcrun"
export PUBLISH_TEST_REAL_GIT="$(command -v git)"
cat > "$WORK/bin/git" <<'STUB'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = fetch ]; then
  printf 'git fetch\n' >> "$PUBLISH_TEST_LOG"
fi
exec "$PUBLISH_TEST_REAL_GIT" "$@"
STUB
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" PUBLISH_TEST_LOG="$WORK/events" PUBLISH_TEST_OBJECTS="$WORK/objects" \
  PUBLISH_TEST_TAP="$WORK/tap.git"

publish() { : > "$WORK/events"; bash "$WORK/repo/scripts/publish_release.sh" > "$WORK/stdout" 2> "$WORK/stderr"; }

expect_refusal() {
  local expected="$1"
  if publish; then echo "期望发布被拒绝：$expected" >&2; exit 1; fi
  grep -q "$expected" "$WORK/stderr" || { echo "错误信息缺少 $expected：" >&2; cat "$WORK/stderr" >&2; exit 1; }
  if grep -Eq '^(upload|geography|gh |api dist/)' "$WORK/events"; then
    echo "拒绝前不应上传或发布：" >&2; cat "$WORK/events" >&2; exit 1
  fi
}

# 版本或构建号不匹配时，必须在 git fetch 和任何发布入口探测之前拒绝。
cp "$DIST/appcast.json" "$WORK/valid-appcast.json"
for mismatch in stale-build missing-build numeric-build wrong-version; do
  python3 - "$WORK/valid-appcast.json" "$DIST/appcast.json" "$mismatch" <<'PY'
import json, pathlib, sys
feed = json.loads(pathlib.Path(sys.argv[1]).read_text())
case = sys.argv[3]
if case == 'stale-build':
    feed['build'] = '998'
elif case == 'missing-build':
    del feed['build']
elif case == 'numeric-build':
    feed['build'] = 999
elif case == 'wrong-version':
    feed['version'] = '9.9.8'
pathlib.Path(sys.argv[2]).write_text(json.dumps(feed))
PY
  expect_refusal 'dist/appcast.json 与升级包不一致'
  [ ! -s "$WORK/events" ] \
    || { echo "$mismatch 在拒绝前触发了远端操作：" >&2; cat "$WORK/events" >&2; exit 1; }
done
cp "$WORK/valid-appcast.json" "$DIST/appcast.json"

# 首次发布：三个制品都上传并回读。
publish || { cat "$WORK/stderr" >&2; exit 1; }
for ext in dmg zip xml; do
  grep -qx "upload XStats-9.9.9-AppleSilicon.$ext" "$WORK/events" || { echo "首次发布缺少 $ext 上传" >&2; exit 1; }
done
grep -qx 'api dist/appcast.json' "$WORK/events" || { echo '首次发布未提交清单' >&2; exit 1; }

# 内容一致的重跑：不再上传，但仍回读校验并继续后续步骤。
publish || { cat "$WORK/stderr" >&2; exit 1; }
if grep -q '^upload ' "$WORK/events"; then echo '内容一致的重跑不应重新上传：' >&2; cat "$WORK/events" >&2; exit 1; fi
grep -qx 'verify XStats-9.9.9-AppleSilicon.zip' "$WORK/events" || { echo '重跑缺少回读校验' >&2; exit 1; }
grep -qx 'api dist/appcast.json' "$WORK/events" || { echo '重跑未提交清单' >&2; exit 1; }

# 源站已有不同内容的同名制品：在任何上传或对外发布前停止，源站内容保持不变。
printf 'previous release' > "$WORK/objects/XStats-9.9.9-AppleSilicon.zip"
expect_refusal '禁止覆盖已发布的 XStats-9.9.9-AppleSilicon.zip'
[ "$(cat "$WORK/objects/XStats-9.9.9-AppleSilicon.zip")" = 'previous release' ] \
  || { echo '已发布制品被改写' >&2; exit 1; }

# 无法确认源站状态时不当作“不存在”。
rm "$WORK/objects/"*
PUBLISH_STAT_ERROR=1 expect_refusal '无法确认源站'
[ -z "$(ls "$WORK/objects")" ] || { echo '查询失败时不应上传' >&2; exit 1; }

# 另一发布者在预检之后创建不同内容，不能覆盖，也不能切换更新清单。
if PUBLISH_RACE=different publish; then echo '并发异内容覆盖未被拒绝' >&2; exit 1; fi
[ "$(cat "$WORK/objects/XStats-9.9.9-AppleSilicon.zip")" = 'concurrent release' ]
! grep -Eq '^gh |^api dist/' "$WORK/events"

# 同内容抢先创建可安全继续，不重写已经公开的对象。
rm -f "$WORK/objects/"*
PUBLISH_RACE=same publish || { cat "$WORK/stderr" >&2; exit 1; }
! grep -q '^upload .*zip' "$WORK/events"
grep -qx 'api dist/appcast.json' "$WORK/events"

# 网络或权限错误不能因为同名对象可读而被误判为成功，原始错误不泄露到日志。
for error in AccessDenied RequestTimeout; do
  rm -f "$WORK/objects/"*
  if PUBLISH_UPLOAD_ERROR="$error" PUBLISH_RACE=same publish; then echo '上传错误未停止发布' >&2; exit 1; fi
  ! grep -Eq '^gh |^api dist/' "$WORK/events"
  ! grep -q 'fixture-secret-must-not-leak' "$WORK/stdout" "$WORK/stderr"
done

echo 'publish_release_test: ok'
