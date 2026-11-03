---
title: "自适应工具栏要先获得标题栏剩余宽度"
author: Ysicing
date: 2026-11-03
branch: main
id: l-5f1c3205
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
  - Packages/XStatsKit/Sources/XStatsUI/AppKit/AppController.swift
  - Packages/XStatsKit/Sources/XStatsUI/Panel/MainWindowView.swift
---

## Decided
网络页工具栏先获得除固定控件外的可用宽度，拖动空白区使用剩余空间。响应式工具栏须同时用宽窗口和最窄窗口的原生截图验证，编译通过不能证明折叠时机正确。

## Tried and ruled out
只加入 ViewThatFits、保留与 Spacer 相同的布局优先级，会让工具栏和空白区分配宽度：第一轮 900／1200 点截图仍有大片空白，工具却提前收入“更多”。工具栏需要更高的布局优先级。

## Watch out
工具按钮在展开与菜单之间切换时，弹窗状态放在候选布局共同的父视图，避免缩放窗口重置当前弹窗。

In the code: Packages/XStatsKit/Sources/XStatsUI/Panel/MainWindowView.swift 的 PageHeader 与 NetworkToolsToolbar；原生走查入口为 XStats --snapshot <目录> --network-tools-only --language zh-Hans，并覆盖 de、ar。
