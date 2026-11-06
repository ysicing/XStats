---
title: SwiftUI 跨时区时钟需要逐行绑定环境时区
author: Ysicing
date: 2026-11-06
branch: main
id: l-b8700d7b
scope: repo
status: active
src: agent
touches:
  - Apps/XStats/Widget/XStatsWidget.swift
  - Packages/XStatsKit/Sources/Localization/Resources/ar.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/de.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/es.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/fr.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/ja.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/ko.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/zh-Hant.tsv
  - Packages/XStatsKit/Sources/Localization/WellnessTranslations.swift
  - Packages/XStatsKit/Sources/WidgetData/WidgetSnapshot.swift
---

## Decided
Bind environment(\.timeZone, zone.timeZone) on each clock row because SwiftUI date Text uses the environment time zone even when Date.FormatStyle specifies another zone. 同一屏的静态和动态时钟共用逐行时区环境。

## Tried and ruled out
只给 Date.FormatStyle 设置时区时，格式化字符串测试通过，但原生截图三行都显示当地时间，日期也错误。原生预览固定跨年瞬间，并用英语时钟文字识别校验真实渲染结果，补足 formatter 单测无法覆盖的视图行为。

## Watch out
修改共享时区格式时保留原生视图验证，不能仅用 formatter 单测证明 SwiftUI 显示正确。

In the code: Packages/XStatsKit/Sources/WidgetData/ClockTimeZone.swift; Apps/XStats/Widget/TimeZoneWidget.swift; Packages/XStatsKit/Sources/XStatsUI/Rest/TimerTimeZoneContent.swift; scripts/snapshot_widgets.py。固定演示瞬间 2026-01-01T00:30:12Z，UTC 为 1 月 1 日，美西为上一年 12 月 31 日。
