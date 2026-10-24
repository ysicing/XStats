// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Testing
@testable import XStatsUI

@MainActor
struct ThumbnailMaintenanceTests {
  private func controller(
    reset: @escaping @Sendable () async throws -> Void
  ) -> MaintenanceController {
    MaintenanceController(
      helper: HelperClient(teamIdentifier: nil, service: SystemHelperRegistration()),
      resetThumbnailCache: reset)
  }

  @Test func successfulResetReleasesBusyState() async {
    let maintenance = controller(reset: {})
    await maintenance.resetThumbnails()
    #expect(!maintenance.isResettingThumbnails)
    #expect(maintenance.thumbnailOutcome?.isError == false)
    #expect(maintenance.running == nil)
  }

  @Test func failedResetReleasesBusyState() async {
    let maintenance = controller {
      throw ToolExecutionError.failed(tool: "qlmanage", status: 1, output: "fixture failure")
    }
    await maintenance.resetThumbnails()
    #expect(!maintenance.isResettingThumbnails)
    #expect(maintenance.thumbnailOutcome?.isError == true)
  }

  @Test(.timeLimit(.minutes(1))) func duplicateResetIsIgnoredAndCancelledResultIsDiscarded() async {
    let gate = Gate()
    let maintenance = controller { await gate.run() }
    let task = Task { await maintenance.resetThumbnails() }
    await gate.waitForStart()
    #expect(maintenance.isResettingThumbnails)
    await maintenance.resetThumbnails()
    // 共用维护忙碌状态：此调用必须直接返回，不能连接 Helper 或请求授权。
    await maintenance.run(.flushDNS)
    #expect(maintenance.running == nil)
    #expect(await gate.calls == 1)
    task.cancel()
    await gate.finish()
    await task.value
    #expect(!maintenance.isResettingThumbnails && maintenance.thumbnailOutcome == nil)
    await maintenance.resetThumbnails()
    #expect(maintenance.thumbnailOutcome?.isError == false)
  }

  private actor Gate {
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    var finished = false

    func run() async {
      calls += 1
      if finished { return }
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        started?.resume()
        started = nil
      }
    }

    func waitForStart() async {
      if calls > 0 { return }
      await withCheckedContinuation { started = $0 }
    }

    func finish() {
      finished = true
      continuation?.resume()
      continuation = nil
    }
  }
}
