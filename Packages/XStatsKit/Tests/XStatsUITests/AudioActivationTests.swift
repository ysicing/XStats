// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import AudioControl
@testable import XStatsUI

private final class ActivationProbe: AudioAccessProbe {
  let denied: Bool
  init(denied: Bool) { self.denied = denied }
  func start(shouldContinue: () -> Bool) throws {
    if denied { throw AudioControlError.permissionRequired }
    if !shouldContinue() { throw CancellationError() }
  }
  func stop() throws {}
}

private final class PendingActivationProbe: AudioAccessProbe, @unchecked Sendable {
  private let lock = NSLock()
  private let release = DispatchSemaphore(value: 0)
  private var starts = 0
  private var stops = 0
  var startCount: Int { lock.withLock { starts } }
  var stopCount: Int { lock.withLock { stops } }
  func start(shouldContinue: () -> Bool) throws {
    let first = lock.withLock {
      starts += 1
      return starts == 1
    }
    // 模拟系统授权在用户取消之后才返回；控制器不能接受这个旧的成功结果。
    if first, release.wait(timeout: .now() + 10) == .timedOut {
      throw AudioControlError.unavailable
    }
  }
  func resume() { release.signal() }
  func stop() throws { lock.withLock { stops += 1 } }
}

@MainActor
struct AudioActivationTests {
  @Test func migrationPreservesTheUsersExistingActivationChoice() throws {
    let suite = "XStats.AudioActivationMigration.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "audio.captureAuthorized")
    let controller = AudioController(defaults: defaults)
    #expect(controller.appVolumeEnabled)
    #expect(defaults.bool(forKey: "audio.appVolumeEnabled"))
    #expect(defaults.object(forKey: "audio.captureAuthorized") == nil)
  }

  @Test(arguments: [false, true])
  func activationPreferenceChangesOnlyAfterSuccessfulInitialization(denied: Bool) async throws {
    let suite = "XStats.AudioActivationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let mixer = AudioMixerClient(
      automaticHealthChecks: false, accessProbeFactory: { ActivationProbe(denied: denied) }
    ) { _, _, _ in
      throw AudioControlError.unavailable
    }
    let controller = AudioController(defaults: defaults, mixer: mixer)
    defer { controller.stop() }
    // 不打开设备界面，避免读取真实蓝牙目录；只验证用户开启偏好的发布时机。
    controller.setDemand(enabled: true, visible: false, menuVisible: true)
    controller.authorizeMixing()
    let deadline = ContinuousClock.now + .seconds(120)
    while controller.isWorking, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!controller.isWorking)
    #expect(controller.appVolumeEnabled == !denied)
    #expect(defaults.bool(forKey: "audio.appVolumeEnabled") == !denied)
    #expect(defaults.object(forKey: "audio.captureAuthorized") == nil)
    #expect(controller.error == (denied ? .permissionRequired : nil))
  }

  @Test func explicitActivationPreferenceTakesPrecedenceOverTheLegacyFlag() throws {
    let suite = "XStats.AudioActivationMigration.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "audio.captureAuthorized")
    defaults.set(false, forKey: "audio.appVolumeEnabled")
    let controller = AudioController(defaults: defaults)
    #expect(!controller.appVolumeEnabled)
    #expect(defaults.object(forKey: "audio.captureAuthorized") == nil)
  }

  @Test(arguments: [false, true])
  func cancellingActivationRejectsLateResultsAndAllowsReactivation(reopen: Bool) async throws {
    let suite = "XStats.AudioActivationCancellation.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let probe = PendingActivationProbe()
    defer { probe.resume() }
    let mixer = AudioMixerClient(
      automaticHealthChecks: false, accessProbeFactory: { probe }
    ) { _, _, _ in throw AudioControlError.unavailable }
    let controller = AudioController(defaults: defaults, mixer: mixer)
    defer { controller.stop() }
    guard controller.supportsMixing else { return }
    controller.setDemand(enabled: true, visible: false, menuVisible: true)
    controller.authorizeMixing()
    let deadline = ContinuousClock.now + .seconds(10)
    while probe.startCount == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(probe.startCount == 1)
    controller.disableMixing()
    #expect(!controller.appVolumeEnabled)
    #expect(!controller.isAuthorizing)
    #expect(!controller.isWorking)
    if reopen { controller.authorizeMixing() }
    probe.resume()
    while probe.stopCount < (reopen ? 2 : 1) || controller.isWorking,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(probe.stopCount == (reopen ? 2 : 1))
    try #require(!controller.isWorking)
    _ = await mixer.unresolvedApplicationIDs()
    #expect(controller.appVolumeEnabled == reopen)
    #expect(defaults.bool(forKey: "audio.appVolumeEnabled") == reopen)
    #expect(controller.error == nil)
  }
}
