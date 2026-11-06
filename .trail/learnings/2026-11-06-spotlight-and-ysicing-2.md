---
title: Spotlight 单独星号返回空结果，和单项 AND 崩溃无关
author: Ysicing
date: 2026-11-06
branch: main
id: l-a53886cd
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
按需拼音候选使用文件名 != "" 收集，并以原生 Spotlight 文件查询验证召回。

## Tried and ruled out
LIKE "*" 的 NSMetadataQuery 能启动且不崩溃，但真实查询返回零条。对同一份已经索引的临时中文文件，精确名称、*.txt 和文件名 != "" 各能命中一条，单独 * 仍为零。因此不能用单独星号代表全部文件。这是合法查询的空结果问题，与已有 learning 中单项 AND 引发 Objective-C 异常是两种独立故障。

## Watch out
新文件需等待 Spotlight 索引。拼音候选仅在本次文件搜索模式内复用；端到端测试重试前应 stop 清除旧快照，清理自建临时文件，不操作真实用户文件。

In the code: Packages/XStatsKit/Sources/XStatsUI/AppKit/CommandBarLiveSearch.swift 与 Packages/XStatsKit/Tests/XStatsUITests/CommandBarLiveSearchTests.swift。XSTATS_LIVE_FILE_SEARCH=1 swift test --package-path Packages/XStatsKit --jobs 1 --no-parallel --filter CommandBarLiveSearchTests。
