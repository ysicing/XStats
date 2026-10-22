// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Foundation
import Testing
@testable import AudioControl
@testable import XStatsUI

private final class PendingDefaultSelection: @unchecked Sendable {
  private let lock = NSLock()
  private var writes = 0
  let release = DispatchSemaphore(value: 0)
  let signal: AsyncStream<Void>.Continuation
  init(signal: AsyncStream<Void>.Continuation) { self.signal = signal }
  func select(_ cancellation: AudioOperationCancellation) -> AudioControlError? {
    signal.yield(())
    signal.finish()
    _ = release.wait(timeout: .now() + 60)
    if cancellation.isCancelled { return .routeChanged }
    lock.withLock { writes += 1 }
    return nil
  }
  var writeCount: Int { lock.withLock { writes } }
}

private final class OutputSwitchState: @unchecked Sendable {
  private let lock = NSLock()
  private var log: [String] = []
  private var blocksSnapshot = false
  private var blocksGuard = false
  private var failsStart = false
  private var pipelineCount = 0
  private var guardCount = 0
  let selectionRelease = DispatchSemaphore(value: 0)
  let snapshotRelease = DispatchSemaphore(value: 0)
  let guardRelease = DispatchSemaphore(value: 0)
  let events: AsyncStream<String>
  private let signal: AsyncStream<String>.Continuation
  let snapshot: AudioHardwareSnapshot
  let selectionError: AudioControlError?

  init(selectionError: AudioControlError? = nil) {
    self.selectionError = selectionError
    let stream = AsyncStream<String>.makeStream()
    events = stream.stream
    signal = stream.continuation
    snapshot = AudioHardwareSnapshot(
      devices: [
        AudioDeviceInfo(id: 1, uid: "test.a", name: "A", hasOutput: true),
        AudioDeviceInfo(id: 2, uid: "test.b", name: "B", hasOutput: true),
      ], outputID: 1, inputID: nil,
      applications: [
        AudioApplication(id: "muted", name: "Muted", processObjectIDs: [101], isPlaying: true)
      ])
  }

  var entries: [String] { lock.withLock { log } }
  func record(_ event: String) {
    lock.withLock { log.append(event) }
    signal.yield(event)
  }
  func wait(for event: String) async {
    if entries.contains(event) { return }
    for await next in events where next == event { return }
  }
  func blockSnapshots() { lock.withLock { blocksSnapshot = true } }
  func blockGuardCreation() { lock.withLock { blocksGuard = true } }
  func releaseSnapshots() {
    lock.withLock { blocksSnapshot = false }
    snapshotRelease.signal()
  }
  func failRecovery(_ fail: Bool) { lock.withLock { failsStart = fail } }
  func readSnapshot() -> AudioHardwareSnapshot {
    if lock.withLock({ blocksSnapshot }) {
      record("snapshot.blocked")
      _ = snapshotRelease.wait(timeout: .now() + 60)
      record("snapshot.released")
    }
    return snapshot
  }
  func select(_ cancellation: AudioOperationCancellation) -> AudioControlError? {
    record("select.started")
    _ = selectionRelease.wait(timeout: .now() + 60)
    record("select.finished")
    return cancellation.isCancelled ? .routeChanged : selectionError
  }
  func makePipeline(_ target: AudioMixTarget, output: String, source: String?)
    -> any AudioMixPipeline
  {
    let number = lock.withLock {
      pipelineCount += 1
      return pipelineCount
    }
    return SwitchPipeline(
      target: target, outputUID: output, sourceUID: source, state: self, number: number)
  }
  func startPipeline(_ number: Int) throws {
    record("pipeline.start.\(number)")
    if lock.withLock({ failsStart }) { throw AudioControlError.unsupportedFormat }
  }
  func makeGuard() -> any AudioOutputSwitchGuard {
    let number = lock.withLock {
      guardCount += 1
      return guardCount
    }
    record("guard.create.\(number)")
    if lock.withLock({ blocksGuard }) {
      record("guard.blocked")
      _ = guardRelease.wait(timeout: .now() + 60)
    }
    return SwitchGuard(state: self, number: number)
  }
}

private final class SwitchPipeline: AudioMixPipeline {
  let target: AudioMixTarget
  let outputUID: String
  let sourceUID: String?
  let state: OutputSwitchState
  let number: Int
  var processIDs: [UInt32] { target.processObjectIDs }
  var frameCount: UInt64 { 1 }
  var isOutputPresent: Bool { true }
  init(
    target: AudioMixTarget, outputUID: String, sourceUID: String?, state: OutputSwitchState,
    number: Int
  ) {
    self.target = target
    self.outputUID = outputUID
    self.sourceUID = sourceUID
    self.state = state
    self.number = number
  }
  func matches(_ target: AudioMixTarget, outputUID: String, sourceUID: String?) -> Bool {
    self.target.id == target.id && processIDs == target.processObjectIDs
      && self.outputUID == outputUID && self.sourceUID == sourceUID
  }
  func start(shouldContinue: () -> Bool) throws { try state.startPipeline(number) }
  func setVolume(_ volume: Float) { state.record("pipeline.gain.\(number).\(volume)") }
  func stop() throws { state.record("pipeline.stop.\(number)") }
}

private final class SwitchGuard: AudioOutputSwitchGuard {
  let id: UInt32 = 77
  let state: OutputSwitchState
  let number: Int
  init(state: OutputSwitchState, number: Int) {
    self.state = state
    self.number = number
  }
  func stop() throws { state.record("guard.stop.\(number)") }
}

@MainActor
private final class OutputSwitchFixture {
  let state: OutputSwitchState
  let mixer: AudioMixerClient
  let hardware: AudioHardwareClient
  let controller: AudioController
  let notifications = NotificationCenter()
  let suite = "XStats.OutputSwitchRecovery.\(UUID())"
  let defaults: UserDefaults

  init(selectionError: AudioControlError? = nil) throws {
    let state = OutputSwitchState(selectionError: selectionError)
    self.state = state
    mixer = AudioMixerClient(
      automaticHealthChecks: false, outputGuardFactory: { _ in state.makeGuard() },
      factory: { state.makePipeline($0, output: $1, source: $2) })
    hardware = AudioHardwareClient(
      selectDevice: { _, _, cancellation in state.select(cancellation) },
      applicationActivity: { [] }, readSnapshot: { _ in state.readSnapshot() })
    defaults = try #require(UserDefaults(suiteName: suite))
    controller = AudioController(
      defaults: defaults, mixer: mixer, hardware: hardware, sleepNotifications: notifications)
    controller.showPreview(
      state.snapshot, volumes: ["muted": try #require(AudioAppVolume(level: 0, isMuted: true))],
      outputs: [:])
  }

  func startSwitch() async throws -> Task<Void, Never> {
    controller.setDemand(enabled: true, visible: false, menuVisible: true)
    await state.wait(for: "pipeline.gain.1.0.0")
    _ = await mixer.unresolvedApplicationIDs()
    let operation = try #require(controller.selectDevice(2, direction: .output))
    await state.wait(for: "select.started")
    return operation
  }

  func closeMenu() {
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
  }

  func stop() async {
    state.selectionRelease.signal()
    state.guardRelease.signal()
    state.releaseSnapshots()
    controller.stop()
    await mixer.stop()
    _ = await hardware.snapshot(includeApplications: false)
    defaults.removePersistentDomain(forName: suite)
  }
}

@MainActor
struct AudioDeviceSwitchTests {
  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func cancellationKeepsTheGuardUntilTheBackgroundSnapshotRestoresMixing(changesVolume: Bool)
    async throws
  {
    let fixture = try OutputSwitchFixture()
    let operation = try await fixture.startSwitch()
    fixture.state.blockSnapshots()
    fixture.closeMenu()
    fixture.state.selectionRelease.signal()
    await operation.value
    await fixture.state.wait(for: "snapshot.blocked")
    _ = await fixture.mixer.unresolvedApplicationIDs()
    #expect(!fixture.state.entries.contains("guard.stop.1"))
    #expect(!fixture.state.entries.contains("pipeline.start.2"))
    if changesVolume {
      fixture.controller.setAppLevel(0.25, app: fixture.state.snapshot.applications[0])
      _ = await fixture.mixer.unresolvedApplicationIDs()
      #expect(!fixture.state.entries.contains("pipeline.start.2"))
      #expect(!fixture.state.entries.contains("guard.stop.1"))
    }
    fixture.state.releaseSnapshots()
    let restoredEvent = changesVolume ? "pipeline.gain.2.0.25" : "pipeline.gain.2.0.0"
    await fixture.state.wait(for: restoredEvent)
    await fixture.state.wait(for: "guard.stop.1")
    let entries = fixture.state.entries
    let restored = try #require(entries.firstIndex(of: restoredEvent))
    let released = try #require(entries.firstIndex(of: "guard.stop.1"))
    #expect(restored < released)
    await fixture.stop()
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellationDuringGuardPreparationStillRestoresBeforeRelease() async throws {
    let fixture = try OutputSwitchFixture()
    fixture.controller.setDemand(enabled: true, visible: false, menuVisible: true)
    await fixture.state.wait(for: "pipeline.gain.1.0.0")
    fixture.state.blockGuardCreation()
    let operation = try #require(fixture.controller.selectDevice(2, direction: .output))
    await fixture.state.wait(for: "guard.blocked")
    fixture.closeMenu()
    fixture.state.guardRelease.signal()
    await operation.value
    await fixture.state.wait(for: "guard.stop.1")
    let entries = fixture.state.entries
    #expect(!entries.contains("select.started"))
    let restored = try #require(entries.firstIndex(of: "pipeline.gain.2.0.0"))
    let released = try #require(entries.firstIndex(of: "guard.stop.1"))
    #expect(restored < released)
    await fixture.stop()
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func completedOrFailedSelectionRestoresBeforeReleasingTheGuard(fails: Bool) async throws {
    let fixture = try OutputSwitchFixture(selectionError: fails ? .hardware(-9) : nil)
    let operation = try await fixture.startSwitch()
    fixture.state.selectionRelease.signal()
    await operation.value
    await fixture.state.wait(for: "guard.stop.1")
    let entries = fixture.state.entries
    let restored = try #require(entries.firstIndex(of: "pipeline.gain.2.0.0"))
    let released = try #require(entries.firstIndex(of: "guard.stop.1"))
    #expect(restored < released)
    #expect(fixture.controller.error == (fails ? .hardware(-9) : nil))
    await fixture.stop()
  }

  @Test(.timeLimit(.minutes(1)))
  func failedRecoveryKeepsProtectionUntilExplicitRetry() async throws {
    let fixture = try OutputSwitchFixture()
    let operation = try await fixture.startSwitch()
    fixture.state.failRecovery(true)
    fixture.closeMenu()
    fixture.state.selectionRelease.signal()
    await operation.value
    await fixture.state.wait(for: "pipeline.stop.2")
    _ = await fixture.mixer.unresolvedApplicationIDs()
    #expect(!fixture.state.entries.contains("guard.stop.1"))
    #expect(await fixture.mixer.unresolvedApplicationIDs() == ["muted"])
    fixture.state.failRecovery(false)
    fixture.controller.retryMixing()
    await fixture.state.wait(for: "guard.stop.1")
    let entries = fixture.state.entries
    let restored = try #require(entries.firstIndex(of: "pipeline.gain.3.0.0"))
    let released = try #require(entries.firstIndex(of: "guard.stop.1"))
    #expect(restored < released)
    await fixture.stop()
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func disablingOrSleepingDuringRecoveryStopsWithoutRestoring(sleep: Bool) async throws {
    let fixture = try OutputSwitchFixture()
    let operation = try await fixture.startSwitch()
    fixture.state.blockSnapshots()
    fixture.closeMenu()
    fixture.state.selectionRelease.signal()
    await operation.value
    await fixture.state.wait(for: "snapshot.blocked")
    if sleep {
      fixture.notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
    } else {
      fixture.controller.setDemand(enabled: false, visible: false, menuVisible: false)
    }
    await fixture.state.wait(for: "guard.stop.1")
    fixture.state.releaseSnapshots()
    await fixture.stop()
    #expect(!fixture.state.entries.contains("pipeline.start.2"))
    #expect(fixture.state.entries.filter { $0 == "guard.stop.1" }.count == 1)
  }

  @Test func fixedRoutesAreGuardedEvenAtOriginalVolumeOnTheDefaultOutput() throws {
    let suite = "XStats.AudioFixedRouteTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = AudioController(defaults: defaults)
    let apps = [
      AudioApplication(id: "fixed", name: "Fixed", processObjectIDs: [11], isPlaying: true),
      AudioApplication(id: "native", name: "Native", processObjectIDs: [12], isPlaying: true),
      AudioApplication(id: "paused", name: "Paused", processObjectIDs: [13], isPlaying: false),
      AudioApplication(id: "missing", name: "Missing", processObjectIDs: [14], isPlaying: true),
    ]
    let output = AudioDeviceInfo(id: 1, uid: "default", name: "Default", hasOutput: true)
    controller.showPreview(
      AudioHardwareSnapshot(devices: [output], outputID: 1, inputID: nil, applications: apps),
      volumes: [:], outputs: ["fixed": "default", "paused": "default", "missing": "missing"])
    #expect(controller.volume(for: apps[0]).level == 1)
    #expect(controller.outputSwitchProcessIDs == [11])
  }

  @Test(arguments: [AudioDirection.input, .output])
  func disablingCancelsAnOrdinaryDeviceSwitchBeforeItsQueuedWrite(direction: AudioDirection)
    async throws
  {
    let suite = "XStats.AudioDeviceSwitchTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let (started, signal) = AsyncStream<Void>.makeStream()
    let gate = PendingDefaultSelection(signal: signal)
    defer { gate.release.signal() }
    let hardware = AudioHardwareClient(selectDevice: { _, _, cancellation in
      gate.select(cancellation)
    })
    let controller = AudioController(defaults: defaults, hardware: hardware)
    defer { controller.stop() }
    let a = AudioDeviceInfo(id: 1, uid: "test.a", name: "A", hasInput: true, hasOutput: true)
    let b = AudioDeviceInfo(id: 2, uid: "test.b", name: "B", hasInput: true, hasOutput: true)
    controller.showPreview(
      AudioHardwareSnapshot(devices: [a, b], outputID: 1, inputID: 1, applications: []),
      volumes: [:], outputs: [:])
    // 不展示设备页或菜单栏，避免真实蓝牙目录读取；选择和写入使用替身。
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    controller.selectDevice(b.id, direction: direction)
    for await _ in started { break }
    controller.setDemand(enabled: false, visible: false, menuVisible: false)
    gate.release.signal()
    _ = await hardware.snapshot(includeApplications: false)  // 串行屏障，确保队列中的选择已经返回。
    #expect(gate.writeCount == 0)
    #expect(!controller.isWorking)
    #expect(controller.error == nil)
  }
}
