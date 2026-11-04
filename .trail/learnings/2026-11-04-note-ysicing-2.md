---
title: "分类切换与参数查询要按同一次状态变化处理"
author: Ysicing
date: 2026-11-04
branch: main
id: l-5d9e15ac
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
将应用服务的目标分类与待消费 Homebrew 查询合并为一个 Equatable 观察值。分类变化时先保存和恢复各分类浏览状态，再应用导航查询并清除请求；初次挂载也处理请求。这样新查询优先于旧分类的搜索恢复，无需增加后台任务。

## Tried and ruled out
独立的查询 task 与分类 onChange 会竞争更新同一个搜索状态：task 可能先写入查询并清空请求，随后分类恢复将搜索重置为空。原生视图回归中 buildkit 与 openssl@3 均复现搜索为空。不要依赖 Task.yield 或固定延时决定回调顺序。

## Watch out
保持普通分类切换时各自的搜索、排序和筛选状态；查询相同分类和首次打开页面也需要消费导航请求。测试使用隔离偏好与演示清单，不执行真实 Homebrew 操作。

In the code: Packages/XStatsKit/Sources/XStatsUI/Panel/AppManagementPage.swift 的 BrowsingDestination 与 onChange；Packages/XStatsKit/Tests/XStatsUITests/AppServicesTests.swift 的 commandQueryReplacesOldHomebrewSearchAcrossCategoryChanges。定向回归 AppServicesTests、ProcessNavigationTests、UninstallerPresentationTests 的 21 项测试通过。
