---
title: "命令栏预览和搜索窗口切换焦点时不能立即销毁会话"
author: Ysicing
date: 2026-11-06
branch: main
id: l-86f037f6
scope: repo
status: active
src: agent
touches:
  - Packages/XStatsKit/Sources/Localization/Resources/ar.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/de.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/es.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/fr.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/ja.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/ko.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/zh-Hant.tsv
  - Packages/XStatsKit/Sources/Localization/Translations.swift
  - Packages/XStatsKit/Sources/XStatsUI/AppKit/AppCommand.swift
  - Packages/XStatsKit/Sources/XStatsUI/AppKit/AppController.swift
---

## Decided
Quick Look 与搜索面板共用会话。存在预览时，失焦通知后让出一次主执行器，再检查两个面板的 isKeyWindow；仅两个都不持有焦点时关闭整个会话。延后回调还须核对 session ID，不能关闭随后重新打开的面板。

## Tried and ruled out
只忽略搜索窗口的失焦、对预览窗口的失焦直接 dismiss，会导致用户从预览点击回搜索框时整个命令栏关闭。原生面板回归测试在修改前稳定出现 panel 和 previewPanel 变 nil，不能用“任何失焦都意味着离开应用”的假设。

## Watch out
NSWindow 的失焦通知发生在新窗口完成焦点切换之前，不能在通知中同步判断最终目标。保留关闭预览恢复搜索、离开两个面板均关闭、旧会话回调无效的验证。

In the code: Packages/XStatsKit/Sources/XStatsUI/AppKit/CommandBarWindowController.swift windowDidResignKey；Packages/XStatsKit/Tests/XStatsUITests/CommandBarLiveSearchTests.swift previewFocusCanReturnToSearchAndLeavingBothPanelsDismisses。
