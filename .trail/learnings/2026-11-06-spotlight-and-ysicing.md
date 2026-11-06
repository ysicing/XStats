---
title: Spotlight 单词查询不能包成单项 AND 谓词
author: Ysicing
date: 2026-11-06
branch: main
id: l-ac95149c
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
Pass a single comparison directly to NSMetadataQuery because a one-child AND throws NSInvalidArgumentException when searchScopes is set. Use an AND only for multiple terms. Keep native start/stop tests because Foundation predicate evaluation does not validate the Spotlight predicate dialect.

## Tried and ruled out
A one-child NSCompoundPredicate passed evaluate(with:) but crashed the native query. A minimal native probe confirmed start succeeds for a direct one-term comparison and a two-term AND. Catching Swift errors cannot recover this Objective-C exception, so fixing the predicate construction is necessary.

## Watch out
Stopped queries can leave already queued notifications. Compare the originating query identity before delivering, otherwise an old finish notification can stop the new query. Bind input through %@ instead of parsing user filenames as query syntax.

In the code:
- Packages/XStatsKit/Sources/XStatsUI/AppKit/CommandBarLiveSearch.swift: CommandBarFileSearch.predicate/start
- Packages/XStatsKit/Tests/XStatsUITests/CommandBarLiveSearchTests.swift: stoppedMetadataQueryCannotDeliverResults
