---
title: "读取旧启动台布局时保留 WAL，系统数据库保持只读"
author: Ysicing
date: 2026-11-05
branch: main
id: l-8e90ee75
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
旧 Launchpad 布局导入先复制数据库及现有 WAL、SHM，再对临时副本运行有界只读查询。复制前后核对源文件大小和修改时间；源文件不稳定时放弃导入，继续使用默认布局。

## Tried and ruled out
不能用 immutable=1 打开原库来规避 SQLite 写入：它会忽略未 checkpoint 的 WAL，导致最新分页与文件夹丢失。直接以只读方式打开仍在使用的源库也可能操作共享内存文件，因此查询应发生在可清理的临时目录。

## Watch out
只读是对用户原始数据库的承诺，不应为了读取布局去 checkpoint、修复或迁移系统库。回归需要创建真实 WAL，并检查导入后原始 db 与 WAL 字节均未改变。

In the code: LaunchpadImport.read 与 LaunchpadImportTests.importsPagesAndFoldersFromWALWithoutChangingSystemDatabase；单次副本总量上限 64 MB，SQL 查询有行数、指令数与时间预算。
