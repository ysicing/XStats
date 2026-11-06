---
title: SwiftUI 时钟须同步格式对象的小时制到环境
author: Ysicing
date: 2026-11-06
branch: main
id: l-233f0a58
scope: repo
status: active
src: agent
touches:
  - Apps/XStats/Widget/TimeZoneWidget.swift
  - Packages/XStatsKit/Sources/WidgetData/ClockTimeZone.swift
  - Packages/XStatsKit/Sources/XStatsUI/Rest/TimerTimeZoneContent.swift
  - Packages/XStatsKit/Tests/XStatsUITests/TimerPopoverTimeZoneTests.swift
  - scripts/snapshot_widgets.py
---

## Decided
中文世界时钟统一使用 00–23 的 24 小时制，避免“凌晨 12”歧义；其他语言保留区域格式。SwiftUI 时间文字必须同时绑定格式对象的 locale，否则 Text(Date, format:) 会重新应用环境 locale，覆盖格式对象中的 hourCycle。

## Tried and ruled out
仅在共享 Date.FormatStyle 的 locale 中设置 hourCycle 为 zeroToTwentyThree，格式化字符串测试通过，但原生截图仍显示“凌晨 12”和“下午 04”。同步时间文字的 environment locale 后，截图才显示 00 和 16。

## Watch out
时区与 locale 都需要原生渲染验证，格式化字符串单测不足以证明 SwiftUI 的最终显示。locale 仅绑定到时间文字，保留其他文字的语言与日期格式；不要改动原有每行的 timeZone 环境。

In the code:
- Packages/XStatsKit/Sources/WidgetData/ClockTimeZone.swift: timeStyle(locale:includesSeconds:)
- Packages/XStatsKit/Sources/XStatsUI/Rest/TimerTimeZoneContent.swift
- Apps/XStats/Widget/TimeZoneWidget.swift
- swift test --package-path Packages/XStatsKit --jobs 2 --no-parallel --filter TimerPopoverTimeZoneTests
- python3 scripts/snapshot_widgets.py <temporary-output-directory>
