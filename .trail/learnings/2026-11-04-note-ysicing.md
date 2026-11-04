---
title: "原生表格里的行内更新按钮要显式适配选中态"
author: Ysicing
date: 2026-11-04
branch: main
id: l-d6158b16
scope: repo
status: active
src: agent
touches:
  - Packages/XStatsKit/Sources/Cleaner/HomebrewManagement.swift
  - Packages/XStatsKit/Sources/Cleaner/ToolExecution.swift
  - Packages/XStatsKit/Sources/Localization/Resources/ar.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/de.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/es.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/fr.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/ja.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/ko.tsv
  - Packages/XStatsKit/Sources/Localization/Resources/zh-Hant.tsv
  - Packages/XStatsKit/Sources/Localization/Translations.swift
---

## Decided
行内更新按钮复用现有 selection，选中时白底蓝字，普通行蓝底白字。Use explicit row selection because native Table button rendering can override tint and foregroundStyle, and backgroundProminence alone does not represent every selected state.

## Tried and ruled out
borderedProminent 加 tint/foregroundStyle 在原生截图里仍出现白字没有清楚按钮底色，因此改用局部 ButtonStyle；不改变系统行选择背景。

## Watch out
离屏快照要同时设置 NSTableRowView.isEmphasized 与 NSTableCellView.backgroundStyle = .emphasized。Otherwise the snapshot can show an emphasized blue background with inactive text colors, which is not the real selected cell appearance.

In the code: Packages/XStatsKit/Sources/XStatsUI/Panel/AppManagementUpdateButton.swift; Packages/XStatsKit/Tests/XStatsUITests/HomebrewConfirmationFlowTests.swift.
