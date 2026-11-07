#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."

RENDER_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/xstats-dock-render.XXXXXX")"
trap 'rm -rf "$RENDER_DIR"' EXIT
swiftc -j2 -parse-as-library \
  Packages/XStatsKit/Sources/DockIcons/DockIconCanvas.swift scripts/render_dock_icon.swift \
  -o "$RENDER_DIR/render-dock-icon"
"$RENDER_DIR/render-dock-icon" "$@"
