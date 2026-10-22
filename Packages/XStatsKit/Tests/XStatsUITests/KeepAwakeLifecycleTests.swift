// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
private final class SleepControlFixture: SleepControlClient {
  var requests: [Bool] = []
  var sleepDisabled = false
  var enableContinuation: CheckedContinuation<String?, Never>?
  var restorationError: String?

  func setSleepDisabled(_ disabled: Bool) async -> String? {
    requests.append(disabled)
    if disabled {
      let result = await withCheckedContinuation { enableContinuation = $0 }
      sleepDisabled = true
      return result
    }
    if let restorationError { return restorationError }
    sleepDisabled = false
    return nil
  }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct KeepAwakeLifecycleTests {
  @Test func stopWaitsForLateEnableAndRestoresSystemSleep() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      let stop = Task { await controller.stop(reason: nil) }
      while controller.isActive {
        try Task.checkCancellation()
        await Task.yield()
      }
      helper.enableContinuation?.resume(returning: nil)
      helper.enableContinuation = nil
      await enable.value
      await stop.value
      #expect(helper.requests == [true, false])
      #expect(!helper.sleepDisabled)
      #expect(!controller.isActive && !controller.lidClosedActive)
      #expect(!controller.requiresTerminationRestoration)
    }
  }

  @Test func canceledCallerStillCompensatesFailedLateEnable() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      enable.cancel()
      let stop = Task { await controller.stop(reason: nil) }
      while controller.isActive {
        try Task.checkCancellation()
        await Task.yield()
      }
      helper.enableContinuation?.resume(returning: "fixture-enable-failure")
      helper.enableContinuation = nil
      await enable.value
      await stop.value
      #expect(helper.requests == [true, false])
      #expect(!helper.sleepDisabled && !controller.requiresTerminationRestoration)
    }
  }

  @Test func failedRestoreRetainsRecoveryRequirementAndCanRetry() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      helper.enableContinuation?.resume(returning: nil)
      helper.enableContinuation = nil
      await enable.value
      helper.restorationError = "fixture-restore-failure"
      await controller.stop(reason: nil)
      #expect(controller.requiresTerminationRestoration)
      #expect(controller.noticeIsError)
      #expect(helper.sleepDisabled)
      helper.restorationError = nil
      await controller.stop(reason: nil)
      #expect(!helper.sleepDisabled && !controller.requiresTerminationRestoration)
    }
  }

  @Test func failedEnableRestoresPotentialPartialSystemChange() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      helper.enableContinuation?.resume(returning: "fixture-enable-failure")
      helper.enableContinuation = nil
      await enable.value
      #expect(helper.requests == [true, false])
      #expect(controller.noticeIsError)
      #expect(!controller.lidClosedRequested && !helper.sleepDisabled)
      #expect(!controller.requiresTerminationRestoration)
    }
  }

  @Test func terminationFreezesIntentWithoutWaitingForTheHelper() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      controller.releaseForTermination()
      #expect(!controller.isActive)
      #expect(controller.requiresTerminationRestoration)
      #expect(helper.enableContinuation != nil)
      helper.enableContinuation?.resume(returning: nil)
      helper.enableContinuation = nil
      await enable.value
      #expect(helper.requests == [true, false])
      #expect(!helper.sleepDisabled && !controller.requiresTerminationRestoration)
    }
  }

  @Test func resumeDuringPendingEnableKeepsLatestRequestWithoutOverlappingWrites() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      let stop = Task { await controller.stop(reason: nil) }
      while controller.isActive {
        try Task.checkCancellation()
        await Task.yield()
      }
      let resume = Task { await controller.start() }
      while !controller.isActive {
        try Task.checkCancellation()
        await Task.yield()
      }
      helper.enableContinuation?.resume(returning: nil)
      helper.enableContinuation = nil
      await enable.value
      await stop.value
      await resume.value
      #expect(helper.requests == [true])
      #expect(controller.isActive && controller.lidClosedActive && helper.sleepDisabled)
    }
  }

  private func withController(
    _ operation: (KeepAwakeController, SleepControlFixture) async throws -> Void
  ) async throws {
    let suite = "KeepAwakeLifecycleTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let helper = SleepControlFixture()
    let controller = KeepAwakeController(helper: helper, settings: AppSettings(defaults: defaults))
    do {
      try await operation(controller, helper)
    } catch {
      helper.enableContinuation?.resume(returning: "fixture-cancelled")
      helper.enableContinuation = nil
      await controller.stop(reason: nil)
      throw error
    }
    await controller.stop(reason: nil)
  }
}
