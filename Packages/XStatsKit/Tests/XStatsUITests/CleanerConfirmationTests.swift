// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import Cleaner
import Foundation
import Localization
import Testing
@testable import XStatsUI

@MainActor
struct CleanerConfirmationTests {
  @Test(arguments: [false, true])
  func trashAlwaysWarnsAboutPermanentDeletion(preferTrash: Bool) throws {
    let confirmation = CleanerConfirmation(
      scans: [try scan("trash", bytes: 714_000_000)], preferTrash: preferTrash)
    #expect(confirmation.kind == .trashOnly)
    #expect(confirmation.permanentCount == 1 && confirmation.recoverableCount == 0)
    #expect(confirmation.permanentBytes == 714_000_000)
    #expect(confirmation.buttonTitle == tr("永久删除"))
  }

  @Test(arguments: [false, true])
  func mixedSelectionFollowsExecutionPolicy(preferTrash: Bool) throws {
    let confirmation = CleanerConfirmation(
      scans: [
        try scan("trash", bytes: 100), try scan("system.caches", bytes: 200),
        try scan("downloads.installers", bytes: 300),
      ], preferTrash: preferTrash)
    #expect(confirmation.kind == .mixed)
    #expect(confirmation.permanentCount == (preferTrash ? 1 : 2))
    #expect(confirmation.permanentBytes == (preferTrash ? 100 : 300))
    #expect(confirmation.recoverableBytes == (preferTrash ? 500 : 300))
    #expect(confirmation.buttonTitle == tr("确认清理"))
  }

  @Test func recoverableAndPermanentSelectionsUseDifferentActions() throws {
    let caches = [try scan("system.caches", bytes: 200)]
    let recoverable = CleanerConfirmation(scans: caches, preferTrash: true)
    let permanent = CleanerConfirmation(scans: caches, preferTrash: false)
    #expect(recoverable.kind == .recoverable)
    #expect(permanent.kind == .permanent)
    #expect(recoverable.buttonTitle == tr("移到废纸篓"))
    #expect(permanent.buttonTitle == tr("永久删除"))
  }

  @Test func toolsRemainPermanentAndKeepPreviewSizeSeparateFromFileTotals() throws {
    let rule = try #require(RuleCatalog.rules().first { $0.id == "developer.homebrew" })
    let items = [CleanItem(url: URL(fileURLWithPath: "/fixture/cache"), size: 10)]
    let scan = RuleScan(
      rule: rule, items: items, skippedCount: 0, blocked: nil,
      toolPreview: ToolCleanupPreview(items: items, totalSize: 500, details: ""))
    let confirmation = CleanerConfirmation(scans: [scan], preferTrash: true)
    #expect(confirmation.kind == .permanent)
    #expect(confirmation.permanentBytes == 0)
    #expect(confirmation.toolPreviews.map(\.bytes) == [500])
    #expect(confirmation.includesHomebrew)
  }

  @Test func overlappingToolPlansDoNotInflateFileTotalsOrBecomePartialSelections() throws {
    let rules = try ["developer.npm", "developer.uv"].map { id in
      try #require(RuleCatalog.rules().first { $0.id == id })
    }
    let item = CleanItem(url: URL(fileURLWithPath: "/fixture/shared"), size: 100)
    let scans = rules.map { RuleScan(rule: $0, items: [item], skippedCount: 0, blocked: nil) }
    let confirmation = CleanerConfirmation(
      scans: scans + [try scan("system.caches", bytes: 200)], preferTrash: false)
    #expect(confirmation.permanentBytes == 200)
    #expect(confirmation.toolPreviews.map(\.bytes) == [100, 100])
    #expect(confirmation.permanentCount == 1)
  }

  @Test func appRunningNoteAppearsOnlyWhenItemsMayBeSkipped() throws {
    let apps = CleanerConfirmation(
      scans: [try scan("app.slack", bytes: 100)], preferTrash: false)
    let trash = CleanerConfirmation(scans: [try scan("trash", bytes: 100)], preferTrash: false)
    let note = tr("正在运行的应用对应的项目会被跳过，实际处理数量可能少于上述数量。")
    #expect(apps.mayBeSkippedWhileAppRunning && apps.message.contains(note))
    #expect(!trash.mayBeSkippedWhileAppRunning && !trash.message.contains(note))
  }

  private func scan(_ id: String, bytes: UInt64) throws -> RuleScan {
    let rule = try #require(RuleCatalog.rules().first { $0.id == id })
    return RuleScan(
      rule: rule, items: [CleanItem(url: URL(fileURLWithPath: "/fixture/" + id), size: bytes)],
      skippedCount: 0, blocked: nil)
  }
}
