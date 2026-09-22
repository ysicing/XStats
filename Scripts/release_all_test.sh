#!/bin/bash
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
[ -f Scripts/release_all.sh ] || { echo "缺少 Scripts/release_all.sh" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

setup() {
  rm -rf "${WORK:?}/repo" "${WORK:?}/bin"
  mkdir -p "$WORK/repo/Scripts" "$WORK/repo/Assets/readme" "$WORK/bin"
  cp "$ROOT/Scripts/release_all.sh" "$WORK/repo/Scripts/release_all.sh"
  chmod +x "$WORK/repo/Scripts/release_all.sh"
  cat > "$WORK/repo/project.yml" <<'YAML'
settings:
  base:
    MARKETING_VERSION: "0.7.0"
    CURRENT_PROJECT_VERSION: "110"
YAML
  cat > "$WORK/repo/CHANGELOG.md" <<'LOG'
# 更新日志

## 0.8.0 · 2026-09-22

- 示例。
LOG
  for file in README.md README.en.md README.ja.md README.ko.md; do
    printf '# XStats\n' > "$WORK/repo/$file"
  done
  : > "$WORK/repo/Assets/readme/activity.svg"
  : > "$WORK/repo/Assets/readme/activity.zh.svg"
  : > "$WORK/log"

  cat > "$WORK/bin/git" <<'SH'
#!/bin/bash
set -euo pipefail
echo "git $*" >> "$RELEASE_ALL_TEST_LOG"
case "${1:-}" in
  symbolic-ref) printf '%s\n' "${FAKE_BRANCH:-main}" ;;
  rev-parse) printf '%s\n' "${FAKE_SHA:-abc123}" ;;
  ls-remote) [ "${FAKE_TAG_EXISTS:-0}" = 1 ] ;;
  diff) [ "${3:-}" != --quiet ] ;;
esac
SH
  cat > "$WORK/bin/task" <<'SH'
#!/bin/bash
set -euo pipefail
echo "task $*" >> "$RELEASE_ALL_TEST_LOG"
if [ "${1:-}" = release ]; then
  sed -i '' -E 's/(MARKETING_VERSION: *)"[^"]+"/\1"0.8.0"/' project.yml
  sed -i '' -E 's/(CURRENT_PROJECT_VERSION: *)"[^"]+"/\1"111"/' project.yml
fi
SH
  cat > "$WORK/bin/python3" <<'SH'
#!/bin/bash
set -euo pipefail
echo "python3 $*" >> "$RELEASE_ALL_TEST_LOG"
printf 'abc123\n'
SH
  cat > "$WORK/repo/Scripts/publish_release.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo publish >> "$RELEASE_ALL_TEST_LOG"
SH
  chmod +x "$WORK/bin/git" "$WORK/bin/task" "$WORK/bin/python3" \
    "$WORK/repo/Scripts/publish_release.sh"
}

expect_failure() {
  local message="$1"
  shift
  if "$@" >"$WORK/stdout" 2>"$WORK/stderr"; then
    echo "错误地成功：$message" >&2
    exit 1
  fi
}

setup
expect_failure "缺少发布 token" env -u XSTATS_RELEASE_TOKEN \
  PATH="$WORK/bin:$PATH" RELEASE_ALL_TEST_LOG="$WORK/log" \
  "$WORK/repo/Scripts/release_all.sh"
grep -q 'XSTATS_RELEASE_TOKEN' "$WORK/stderr" \
  || { cat "$WORK/stderr" >&2; exit 1; }
[ ! -s "$WORK/log" ] || { echo "缺少 token 时不应执行任何命令" >&2; exit 1; }

setup
expect_failure "非 main 分支" env XSTATS_RELEASE_TOKEN=test FAKE_BRANCH=feature \
  PATH="$WORK/bin:$PATH" RELEASE_ALL_TEST_LOG="$WORK/log" \
  "$WORK/repo/Scripts/release_all.sh"
grep -q 'main' "$WORK/stderr" || { cat "$WORK/stderr" >&2; exit 1; }
grep -qx 'git symbolic-ref --quiet --short HEAD' "$WORK/log"

setup
env XSTATS_RELEASE_TOKEN=test PATH="$WORK/bin:$PATH" RELEASE_ALL_TEST_LOG="$WORK/log" \
  "$WORK/repo/Scripts/release_all.sh"
cat > "$WORK/expected" <<'LOG'
git symbolic-ref --quiet --short HEAD
git fetch --quiet origin main
git rev-parse HEAD
git rev-parse origin/main
git ls-remote --exit-code --tags origin refs/tags/v0.8.0
python3 Scripts/release_provenance.py prepare
task test
task release
python3 Scripts/release_provenance.py prepare
git add -- project.yml CHANGELOG.md README.md README.en.md README.ja.md README.ko.md Assets/readme/activity.svg Assets/readme/activity.zh.svg
git diff --cached --quiet
git commit -m chore(release): 发布 0.8.0
git push origin main
publish
LOG
diff -u "$WORK/expected" "$WORK/log"

echo "一键发布脚本测试通过"
