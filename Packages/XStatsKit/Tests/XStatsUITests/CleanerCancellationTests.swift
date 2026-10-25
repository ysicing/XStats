// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct CleanerCancellationTests {
  @Test func cancellationKeepsMutualExclusionUntilExitAndDiscardsLateResults() async throws {
    let suite = "CleanerCancellationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.cleanerEnabled = true
    let gate = ScanGate()
    let mole = MoleController(
      settings: settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, _, _ in
        Issue.record("Mole started while native scan was stopping")
        return 0
      })
    await mole.refreshAvailability()
    let rule = try #require(RuleCatalog.rules().first { $0.id == "system.caches" })
    let late = RuleScan(
      rule: rule,
      items: [CleanItem(url: URL(fileURLWithPath: "/fixture/cache"), size: 1024)],
      skippedCount: 0, blocked: nil)
    let controller = CleanerController(
      settings: settings, mole: mole,
      scanOperation: { _, _ in
        await gate.wait()
        return (nil, [late])
      })
    controller.scan()
    await gate.waitUntilStarted()
    controller.cancelOperation()
    #expect(controller.isCancelling)
    #expect(controller.isBusy && controller.phase == .scanning)
    controller.scan()
    controller.requestClean()
    #expect(!controller.isConfirming)
    #expect(!mole.canStart && !mole.canExecute)
    mole.scan()
    mole.requestExecution()
    #expect(!mole.isRunning && !mole.isConfirming)
    var didExit = false
    var waitStarted = false
    let exit = Task {
      waitStarted = true
      await controller.waitForExit()
      didExit = true
    }
    while !waitStarted { await Task.yield() }
    #expect(!didExit)
    await gate.release()
    await exit.value
    #expect(didExit)
    await waitUntilIdle(controller)
    #expect(controller.phase == .idle && !controller.isCancelling)
    #expect(controller.scans.isEmpty && controller.lastScan == nil)
    #expect(await gate.starts == 1)
    controller.scan()
    await waitUntilIdle(controller)
    #expect(controller.phase == .ready && controller.scans.map(\.id) == [rule.id])
    #expect(await gate.starts == 2)
  }

  @Test func cancelledRescanKeepsPreviousCompletedPreview() async throws {
    let suite = "CleanerCancelledRescanTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.cleanerEnabled = true
    let gate = ScanGate()
    let controller = CleanerController(
      settings: settings,
      scanOperation: { _, _ in
        await gate.wait()
        return (nil, [])
      })
    let rule = try #require(RuleCatalog.rules().first)
    controller.showPreview([RuleScan(rule: rule, items: [], skippedCount: 0, blocked: nil)])
    let previousDate = controller.lastScan
    controller.scan()
    await gate.waitUntilStarted()
    controller.cancelOperation()
    await gate.release()
    await waitUntilIdle(controller)
    #expect(controller.phase == .ready)
    #expect(controller.scans.map(\.id) == [rule.id] && controller.lastScan == previousDate)
    #expect(!controller.isCancelling)
  }

  private func waitUntilIdle(_ controller: CleanerController) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while controller.isBusy && ContinuousClock.now < deadline { await Task.yield() }
    #expect(!controller.isBusy)
  }
}

private actor ScanGate {
  var starts = 0
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  func wait() async {
    starts += 1
    guard !released else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilStarted() async {
    while starts == 0 { await Task.yield() }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
