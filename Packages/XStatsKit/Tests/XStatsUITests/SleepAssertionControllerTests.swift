// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Darwin
import IOKit.pwr_mgt
import Metrics
import Testing
@testable import XStatsUI

private actor SleepReadGate {
  var calls = 0
  var pending: [CheckedContinuation<[SleepBlockingProcess], Never>] = []
  func read() async -> [SleepBlockingProcess] {
    calls += 1
    return await withCheckedContinuation { pending.append($0) }
  }
  func finish() {
    let pending = pending
    self.pending = []
    for continuation in pending { continuation.resume(returning: []) }
  }
}

@MainActor
struct SleepAssertionControllerTests {
  @Test func closesAndPausesDiscardPendingReadsAndDoNotRestartWhilePaused() async throws {
    let gate = SleepReadGate()
    let controller = SleepAssertionController(read: { await gate.read() })
    controller.setVisible(true)
    controller.setVisible(true)
    try await wait(for: 1, gate: gate)
    controller.setVisible(false)
    await gate.finish()
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.processes == nil && !controller.isUnavailable)
    #expect(await gate.calls == 1)
    controller.setPaused(true)
    controller.setVisible(true)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await gate.calls == 1)
    controller.setPaused(false)
    try await wait(for: 2, gate: gate)
    controller.setPaused(true)
    await gate.finish()
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.processes == nil)
    controller.setVisible(false)
  }

  @Test func failedReadShowsUnavailableRatherThanAnEmptySuccess() async throws {
    let controller = SleepAssertionController(read: { throw NSError(domain: "Test", code: 1) })
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    // 读取任务同样跑在主 actor 上，机器繁忙时首轮调度可能排在若干用例之后；
    // 这里只放宽等待上限，正常仍会立即满足，不改变断言本身。
    let deadline = ContinuousClock.now + .seconds(30)
    while !controller.isUnavailable && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(controller.isUnavailable && controller.processes == nil)
    controller.setVisible(false)
    #expect(!controller.isUnavailable)
  }

  /// 实机验证请求结束后按周期消失，关闭后跨过一个轮询周期仍不再读取。
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["XSTATS_SLEEP_ASSERTION_RESOURCE_REPORT"] != nil))
  func nativePollingStopsAfterClosing() async throws {
    let path = try #require(
      ProcessInfo.processInfo.environment["XSTATS_SLEEP_ASSERTION_RESOURCE_REPORT"])
    let counter = SleepReadCounter()
    let controller = SleepAssertionController(read: {
      await counter.increment()
      return try await Task.detached(priority: .utility) { try SleepAssertionReader.read() }.value
    })
    defer { controller.setVisible(false) }
    let started = ContinuousClock.now
    let cpuBefore = cpuSeconds()
    let reason = "XStats refresh test \(UUID())"
    var assertion: IOPMAssertionID = 0
    let status = IOPMAssertionCreateWithName(
      "PreventUserIdleSystemSleep" as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion)
    try #require(status == kIOReturnSuccess)
    defer { if assertion != 0 { IOPMAssertionRelease(assertion) } }
    controller.setVisible(true)
    let initialDeadline = ContinuousClock.now + .seconds(2)
    while controller.processes == nil && ContinuousClock.now < initialDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(controller.processes?.contains { $0.reason.contains(reason) } == true)
    #expect(IOPMAssertionRelease(assertion) == kIOReturnSuccess)
    assertion = 0
    let refreshDeadline = ContinuousClock.now + .seconds(14)
    while controller.processes?.contains(where: { $0.reason.contains(reason) }) == true
      && ContinuousClock.now < refreshDeadline
    {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(controller.processes?.contains { $0.reason.contains(reason) } == false)
    let readsWhenVisible = await counter.calls
    #expect(readsWhenVisible >= 2)
    #expect(controller.processes != nil && !controller.isUnavailable)
    controller.setVisible(false)
    try await Task.sleep(for: .seconds(12))
    #expect(await counter.calls == readsWhenVisible)
    #expect(controller.processes == nil)
    let elapsed = started.duration(to: .now)
    let report =
      "visible_reads=\(readsWhenVisible) closed_reads=\(await counter.calls - readsWhenVisible) cpu_seconds=\(cpuSeconds() - cpuBefore) elapsed=\(elapsed)"
    try report.write(toFile: path, atomically: true, encoding: .utf8)
  }

  private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }

  @Test func onlyVisibleEnabledEnergyPageRequestsAssertions() throws {
    let suite = "SleepAssertionDemand.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    settings.setModuleEnabled(.battery, true)
    settings.panelTab = .battery
    #expect(!model.sleepAssertionsVisible)
    model.isMainWindowVisible = true
    #expect(model.sleepAssertionsVisible)
    settings.setModuleEnabled(.battery, false)
    #expect(!model.sleepAssertionsVisible)
    settings.setModuleEnabled(.battery, true)
    settings.panelTab = .cpu
    #expect(!model.sleepAssertionsVisible)
  }

  private func wait(for calls: Int, gate: SleepReadGate) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await gate.calls < calls && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await gate.calls == calls)
  }
}

private actor SleepReadCounter {
  var calls = 0
  func increment() { calls += 1 }
}
