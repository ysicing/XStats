#!/bin/bash
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

# Only Apple's transient timestamp-service failure is retryable. Keep signing
# arguments identical; never fall back to an unsigned or timestamp-free build.
codesign_with_timestamp_retry() {
  local attempt status output retryable timestamp=0 argument
  for argument in "$@"; do
    [ "$argument" != --timestamp ] || timestamp=1
  done
  for attempt in 1 2 3; do
    output="$(mktemp)" || return 1
    status=0
    LC_ALL=C codesign "$@" >"$output" 2>&1 || status=$?
    cat "$output" >&2
    retryable=0
    if [ "$status" -ne 0 ] && [ "$timestamp" = 1 ] &&
      grep -qF 'The timestamp service is not available.' "$output"; then
      retryable=1
    fi
    rm -f "$output"
    [ "$status" -ne 0 ] || return 0
    if [ "$retryable" != 1 ] || [ "$attempt" = 3 ]; then
      return "$status"
    fi
    echo "签名时间戳服务暂不可用，将重试（已尝试 ${attempt}/3）" >&2
    if [ "$attempt" = 1 ]; then sleep 2; else sleep 5; fi
  done
}
