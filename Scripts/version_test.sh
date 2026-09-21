#!/bin/bash
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/date" <<'SH'
#!/bin/sh
printf '%s\n' 2026.09.21
SH
chmod +x "$WORK/bin/date"

run_case() {
  local initial_version="$1"
  local initial_build="$2"
  local expected_version="$3"
  local expected_build="$4"

  rm -rf "$WORK/case"
  mkdir -p "$WORK/case/Scripts"
  cp "$ROOT/Scripts/version.sh" "$WORK/case/Scripts/version.sh"
  cp "$ROOT/project.yml" "$WORK/case/project.yml"
  sed -i '' -E "s/(MARKETING_VERSION: *)\"?[0-9.]+\"?/\1\"$initial_version\"/" "$WORK/case/project.yml"
  sed -i '' -E "s/(CURRENT_PROJECT_VERSION: *)\"?[0-9.]+\"?/\1\"$initial_build\"/" "$WORK/case/project.yml"

  local actual
  actual="$(cd "$WORK/case" && PATH="$WORK/bin:$PATH" Scripts/version.sh build)"
  if [[ "$actual" != "$expected_version ($expected_build)" ]]; then
    echo "期望 $expected_version ($expected_build)，实际为 $actual" >&2
    return 1
  fi
  grep -q "MARKETING_VERSION: \"$expected_version\"" "$WORK/case/project.yml"
  grep -q "CURRENT_PROJECT_VERSION: \"$expected_build\"" "$WORK/case/project.yml"
}

run_case 0.6.1 0106 2026.09.21.01 0107
run_case 2026.09.21.01 0107 2026.09.21.02 0108
run_case 2026.09.20.99 0108 2026.09.21.01 0109
