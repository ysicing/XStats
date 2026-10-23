// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Testing
@testable import XStatsUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SystemCheckControllerTests {
  @Test func deadlineRejectsLateResultsWithoutStartingAnotherCheck() async throws {
    let gate = Gate()
    let controller = SystemCheckController(timeout: .milliseconds(5)) { _ in await gate.collect() }
    let task = try #require(controller.start())
    await gate.waitForStart()
    await controller.deadlineTask?.value
    #expect(controller.isChecking == false)
    #expect(controller.findings.first?.status == .unchecked)
    await gate.finish(id: "late")
    await task.value
    #expect(controller.findings.first?.id == "timeout")
  }

  @Test func cancellationRejectsLateResultsAndAllowsAFreshCheck() async throws {
    let gate = Gate()
    let controller = SystemCheckController { _ in await gate.collect() }
    let old = try #require(controller.start())
    await gate.waitForStart()
    #expect(controller.start() == nil)
    controller.cancel()
    #expect(controller.isChecking == false)
    await gate.finish(id: "late")
    await old.value
    #expect(controller.findings.isEmpty)
    #expect(controller.checkedAt == nil)
    let fresh = try #require(controller.start())
    await gate.waitForStart()
    await gate.finish(id: "fresh")
    await fresh.value
    #expect(controller.findings.map(\.id) == ["fresh"])
    #expect(controller.checkedAt != nil)
  }

  @Test func pauseStopsChecksAndBlocksNewWorkUntilResumed() async throws {
    let gate = Gate()
    let controller = SystemCheckController { _ in await gate.collect() }
    let task = try #require(controller.start())
    await gate.waitForStart()
    controller.setPaused(true)
    #expect(controller.start() == nil)
    await gate.finish(id: "discarded")
    await task.value
    #expect(controller.findings.isEmpty)
    controller.setPaused(false)
    let fresh = try #require(controller.start())
    await gate.waitForStart()
    await gate.finish(id: "resumed")
    await fresh.value
    #expect(controller.findings.first?.id == "resumed")
  }

  @Test func previewItemsCannotEnterCleanerConfirmation() throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let cleaner = CleanerController(settings: settings)
    let rule = try #require(PreviewRuleCatalog.rules.first)
    let item = CleanItem(url: URL(fileURLWithPath: "/Users/fixture/preview"), size: 4096)
    let scan = RuleScan(rule: rule, items: [item], skippedCount: 0, blocked: nil)
    cleaner.showPreview([scan])
    cleaner.selection = [rule.id]
    cleaner.toggle(item, in: scan)
    cleaner.requestClean()
    #expect(cleaner.selectedScans.isEmpty)
    #expect(cleaner.pendingScans.isEmpty)
    #expect(cleaner.isConfirming == false)
    #expect(cleaner.totalBytes == 0)
    #expect(cleaner.previewBytes == 4096)
  }

  @Test func toolEstimatesStaySeparateWhileWholeToolsRemainSelected() throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let cleaner = CleanerController(settings: AppSettings(defaults: defaults))
    let rules = try ["developer.npm", "developer.uv"].map { id in
      try #require(RuleCatalog.rules().first { $0.id == id })
    }
    let scans = rules.map {
      RuleScan(
        rule: $0, items: [CleanItem(url: URL(fileURLWithPath: "/fixture/shared"), size: 100)],
        skippedCount: 0, blocked: nil)
    }
    cleaner.showPreview(scans)
    cleaner.selection = Set(rules.map(\.id))
    #expect(cleaner.totalBytes == 0)
    #expect(cleaner.selectedBytes == 0)
    #expect(cleaner.selectedScans.map(\.totalSize) == [100, 100])
    cleaner.requestClean()
    #expect(cleaner.pendingScans.map(\.id) == rules.map(\.id))
  }

  private actor Gate {
    var continuation: CheckedContinuation<[SystemCheckFinding], Never>?
    var started: CheckedContinuation<Void, Never>?

    func collect() async -> [SystemCheckFinding] {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        started?.resume()
        started = nil
      }
    }

    func waitForStart() async {
      if continuation != nil { return }
      await withCheckedContinuation { started = $0 }
    }

    func finish(id: String) {
      continuation?.resume(returning: [
        SystemCheckFinding(id: id, title: id, status: .normal, detail: "")
      ])
      continuation = nil
    }
  }
}
