#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -parse-as-library "$ROOT/NetworkMonitorApp/ComponentServiceLifetime.swift" \
  "$ROOT/scripts/network_component_lifetime_test.swift" -o "$WORK/lifetime-test"
"$WORK/lifetime-test"
