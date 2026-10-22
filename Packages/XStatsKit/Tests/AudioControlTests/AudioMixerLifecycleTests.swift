// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import AudioControl

private final class PipelineLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  private var guards: [UInt32: Set<UInt32>] = [:]
  func append(_ item: String) { lock.withLock { items.append(item) } }
  var entries: [String] { lock.withLock { items } }
  func registerGuard(_ id: UInt32, processIDs: [UInt32]) {
    lock.withLock { guards[id] = Set(processIDs) }
  }
  func removeGuard(_ id: UInt32) {
    lock.withLock { _ = guards.removeValue(forKey: id) }
  }
  var guardedProcessIDs: Set<UInt32> {
    lock.withLock { Set(guards.values.flatMap { $0 }) }
  }
}
private final class TestPipeline: AudioMixPipeline, @unchecked Sendable {
  let processIDs: [UInt32]
  let outputUID: String
  let sourceUID: String?
  let id: String
  let log: PipelineLog
  private let lock = NSLock()
  private var stopFailures: Int
  private let startError: AudioControlError?
  var isOutputPresent: Bool { true }
  var frameCount: UInt64 { 1 }  // 只收到首帧，之后不再前进，验证重建预算不会因首帧而重置。
  init(
    _ target: AudioMixTarget, output: String, source: String?, log: PipelineLog,
    stopFailures: Int = 0, startFails: Bool = false, startError: AudioControlError? = nil
  ) {
    id = target.id
    processIDs = target.processObjectIDs
    outputUID = output
    sourceUID = source
    self.log = log
    self.stopFailures = stopFailures
    self.startError = startError ?? (startFails ? .renderStalled : nil)
  }
  func matches(_ target: AudioMixTarget, outputUID: String, sourceUID: String?) -> Bool {
    target.id == id && target.processObjectIDs == processIDs && self.outputUID == outputUID
      && self.sourceUID == sourceUID
  }
  func start(shouldContinue: () -> Bool) throws {
    log.append("start:\(id):\(outputUID)")
    if let startError { throw startError }
  }
  func setVolume(_ volume: Float) {
    log.append("gain:\(id)")
    log.append("volume:\(id):\(outputUID):\(volume)")
  }
  func stop() throws {
    log.append("stop:\(id):\(outputUID)")
    let fails = lock.withLock {
      if stopFailures > 0 {
        stopFailures -= 1
        return true
      }
      return false
    }
    if fails { throw AudioControlError.hardware(-1) }
  }
}
private final class SlotTestOutputGuard: AudioOutputSwitchGuard {
  let id: UInt32
  let log: PipelineLog?
  init(id: UInt32 = 99, log: PipelineLog? = nil, processIDs: [UInt32] = []) {
    self.id = id
    self.log = log
    log?.registerGuard(id, processIDs: processIDs)
  }
  func stop() throws {
    log?.append("guard.stop")
    log?.append("guard.stop:\(id)")
    log?.removeGuard(id)
  }
}
private final class SlotGuardSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var id: UInt32 = 100
  func next() -> UInt32 {
    lock.withLock {
      id += 1
      return id
    }
  }
}
struct AudioMixerLifecycleTests {
  @Test func nextSwitchInheritsGuardCoverageBeforeTheRecoverySnapshot() async throws {
    let log = PipelineLog()
    let guards = SlotGuardSequence()
    let client = AudioMixerClient(
      automaticHealthChecks: false,
      outputGuardFactory: { objects in
        let id = guards.next()
        log.append("guard.create:\(id):\(objects)")
        return SlotTestOutputGuard(id: id, log: log)
      }
    ) {
      TestPipeline($0, output: $1, source: $2, log: log)
    }
    let mutedTarget = AudioMixTarget(
      id: "b", processObjectIDs: [2],
      volume: try #require(AudioAppVolume(level: 1, isMuted: true)))
    try await client.apply([try target("a"), mutedTarget], outputUID: "default")
    let firstGuard = try #require(try await client.prepareOutputSwitch())
    try await client.finishOutputSwitch(firstGuard, afterRestoring: true)

    let secondGuard = try #require(try await client.prepareOutputSwitch())
    let entries = log.entries
    let created = try #require(entries.firstIndex(of: "guard.create:102:[1, 2]"))
    let released = try #require(entries.firstIndex(of: "guard.stop:101"))
    #expect(created < released)
    try await client.finishOutputSwitch(firstGuard)
    try await client.finishOutputSwitch(secondGuard, afterRestoring: true)
    await client.checkHealth(now: 0)
    #expect(!log.entries.contains("guard.stop:102"))
    #expect(log.entries.filter { $0.hasPrefix("start:") }.count == 2)
    await client.stop()
    #expect(log.entries.filter { $0 == "guard.stop:101" }.count == 1)
    #expect(log.entries.filter { $0 == "guard.stop:102" }.count == 1)
  }

  @Test(arguments: [false, true])
  func nextSwitchPreservesGuardCoverageAfterPartialRecovery(clearDemand: Bool) async throws {
    let log = PipelineLog()
    let guards = SlotGuardSequence()
    let client = AudioMixerClient(
      automaticHealthChecks: false,
      outputGuardFactory: { objects in
        let id = guards.next()
        log.append("guard.create:\(id):\(objects)")
        return SlotTestOutputGuard(id: id, log: log)
      }
    ) {
      TestPipeline(
        $0, output: $1, source: $2, log: log,
        startError: $0.id == "b" && $1 != "default" ? .unsupportedFormat : nil)
    }
    let firstTarget = try target("a")
    let mutedTarget = AudioMixTarget(
      id: "b", processObjectIDs: [2],
      volume: try #require(AudioAppVolume(level: 1, isMuted: true)))
    let demand = [firstTarget, mutedTarget]
    try await client.apply(demand, outputUID: "default")
    let firstGuard = try #require(try await client.prepareOutputSwitch())
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply(demand, outputUID: "usb")
    }
    try await client.finishOutputSwitch(firstGuard, afterRestoring: true)
    #expect(await client.unresolvedApplicationIDs() == ["b"])
    #expect(log.entries.contains("volume:a:usb:0.5"))
    #expect(log.entries.contains("guard.create:101:[1, 2]"))
    #expect(!log.entries.contains("guard.stop:101"))

    let secondGuard = try #require(try await client.prepareOutputSwitch())
    let entries = log.entries
    let created = try #require(entries.firstIndex { $0.hasPrefix("guard.create:102:") })
    let released = try #require(entries.firstIndex(of: "guard.stop:101"))
    #expect(entries[created] == "guard.create:102:[1, 2]")
    #expect(created < released)
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply(demand, outputUID: "hdmi")
    }
    try await client.finishOutputSwitch(secondGuard, afterRestoring: true)
    await client.checkHealth(now: 0)
    #expect(await client.unresolvedApplicationIDs() == ["b"])
    #expect(!log.entries.contains("guard.stop:102"))
    let started = log.entries.filter { $0.hasPrefix("start:") }.count
    if clearDemand {
      try await client.apply([], outputUID: "hdmi")
    } else {
      await client.stop()
    }
    try await client.finishOutputSwitch(firstGuard)
    #expect(log.entries.filter { $0 == "guard.stop:101" }.count == 1)
    #expect(log.entries.filter { $0 == "guard.stop:102" }.count == 1)
    #expect(log.entries.filter { $0.hasPrefix("start:") }.count == started)
    #expect(await client.unresolvedApplicationIDs().isEmpty)
    await client.stop()
  }

  @Test func failedSecondPreparationKeepsUnrestoredProcessesGuardedUntilStopped() async throws {
    let log = PipelineLog()
    let guards = SlotGuardSequence()
    let client = AudioMixerClient(
      automaticHealthChecks: false,
      outputGuardFactory: {
        SlotTestOutputGuard(id: guards.next(), log: log, processIDs: $0)
      }
    ) {
      TestPipeline(
        $0, output: $1, source: $2, log: log,
        stopFailures: $0.id == "a" && $1 == "usb" ? 2 : 0,
        startError: $0.id == "b" && $1 == "usb" ? .unsupportedFormat : nil)
    }
    let mutedTarget = AudioMixTarget(
      id: "b", processObjectIDs: [2],
      volume: try #require(AudioAppVolume(level: 1, isMuted: true)))
    let demand = [try target("a"), mutedTarget]
    try await client.apply(demand, outputUID: "default")
    let firstGuard = try #require(try await client.prepareOutputSwitch())
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply(demand, outputUID: "usb")
    }
    try await client.finishOutputSwitch(firstGuard, afterRestoring: true)
    #expect(await client.unresolvedApplicationIDs() == ["b"])
    #expect(log.guardedProcessIDs.contains(2))

    await #expect(throws: AudioControlError.unavailable) {
      _ = try await client.prepareOutputSwitch()
    }
    #expect(log.guardedProcessIDs.contains(2))
    try await client.finishOutputSwitch(firstGuard)
    #expect(log.guardedProcessIDs.contains(2))
    await client.stop()
    #expect(log.guardedProcessIDs.isEmpty)
  }

  @Test(arguments: [false, true])
  func withdrawingOneDemandUnmutesOnlyThatProcessDuringPartialRecovery(remainsInCatalog: Bool)
    async throws
  {
    let log = PipelineLog()
    let guards = SlotGuardSequence()
    let client = AudioMixerClient(
      automaticHealthChecks: false,
      outputGuardFactory: {
        SlotTestOutputGuard(id: guards.next(), log: log, processIDs: $0)
      }
    ) {
      TestPipeline(
        $0, output: $1, source: $2, log: log,
        startError: $0.id == "b" && $1 == "usb" ? .unsupportedFormat : nil)
    }
    let mutedTarget = AudioMixTarget(
      id: "b", processObjectIDs: [2],
      volume: try #require(AudioAppVolume(level: 1, isMuted: true)))
    try await client.apply([try target("a"), mutedTarget], outputUID: "default")
    let guardID = try #require(try await client.prepareOutputSwitch())
    #expect(log.guardedProcessIDs == [1, 2])
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply([try target("a"), mutedTarget], outputUID: "usb")
    }
    try await client.finishOutputSwitch(guardID, afterRestoring: true)
    #expect(log.guardedProcessIDs.contains(2))

    var changed = [mutedTarget]
    if remainsInCatalog {
      changed.append(
        AudioMixTarget(
          id: "a", processObjectIDs: [1], volume: try #require(AudioAppVolume(level: 1))))
    }
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply(changed, outputUID: "usb")
    }
    #expect(await client.unresolvedApplicationIDs() == ["b"])
    #expect(log.entries.contains("stop:a:usb"))
    #expect(log.guardedProcessIDs == [2])
    let restartedTarget = AudioMixTarget(
      id: "b", processObjectIDs: [3], volume: mutedTarget.volume)
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply([restartedTarget], outputUID: "usb")
    }
    #expect(log.guardedProcessIDs == [3])
    let nextGuard = try #require(try await client.prepareOutputSwitch())
    try await client.finishOutputSwitch(guardID)
    #expect(log.guardedProcessIDs == [3])
    try await client.finishOutputSwitch(nextGuard, afterRestoring: true)
    await client.stop()
    #expect(log.guardedProcessIDs.isEmpty)
  }

  @Test func failedGuardCoverageReplacementKeepsProtectionUntilTheNextApply() async throws {
    let log = PipelineLog()
    let guards = SlotGuardSequence()
    let client = AudioMixerClient(
      automaticHealthChecks: false,
      outputGuardFactory: { objects in
        log.append("guard.attempt:\(objects)")
        if objects == [2],
          log.entries.filter({ $0 == "guard.attempt:[2]" }).count == 1
        {
          throw AudioControlError.hardware(-1)
        }
        return SlotTestOutputGuard(id: guards.next(), log: log, processIDs: objects)
      }
    ) {
      TestPipeline(
        $0, output: $1, source: $2, log: log,
        startError: $0.id == "b" && $1 == "usb" ? .unsupportedFormat : nil)
    }
    let mutedTarget = AudioMixTarget(
      id: "b", processObjectIDs: [2],
      volume: try #require(AudioAppVolume(level: 1, isMuted: true)))
    let demand = [try target("a"), mutedTarget]
    try await client.apply(demand, outputUID: "default")
    let guardID = try #require(try await client.prepareOutputSwitch())
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply(demand, outputUID: "usb")
    }
    try await client.finishOutputSwitch(guardID, afterRestoring: true)
    await #expect(throws: AudioControlError.self) {
      try await client.apply([mutedTarget], outputUID: "usb")
    }
    #expect(log.entries.contains("guard.attempt:[2]"))
    #expect(log.guardedProcessIDs == [1, 2])
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply([mutedTarget], outputUID: "usb")
    }
    #expect(log.guardedProcessIDs == [2])
    await client.stop()
    #expect(log.guardedProcessIDs.isEmpty)
  }

  @Test func anUnadmittedApplicationIsNotMutedByADeferredGuard() async throws {
    let log = PipelineLog()
    let guards = SlotGuardSequence()
    let client = AudioMixerClient(
      automaticHealthChecks: false,
      outputGuardFactory: {
        SlotTestOutputGuard(id: guards.next(), log: log, processIDs: $0)
      }
    ) {
      TestPipeline(
        $0, output: $1, source: $2, log: log,
        startError: $0.id == "b8" && $1 == "usb" ? .unsupportedFormat : nil)
    }
    let existing = try (1...8).map { index in
      AudioMixTarget(
        id: "b\(index)", processObjectIDs: [UInt32(index)],
        volume: try #require(AudioAppVolume(level: 0.5)))
    }
    try await client.apply(existing, outputUID: "default")
    let guardID = try #require(try await client.prepareOutputSwitch())
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply(existing, outputUID: "usb")
    }
    try await client.finishOutputSwitch(guardID, afterRestoring: true)
    let newcomer = AudioMixTarget(
      id: "a", processObjectIDs: [9], volume: try #require(AudioAppVolume(level: 0.5)))
    await #expect(throws: AudioControlError.processingLimit(8)) {
      try await client.apply(existing + [newcomer], outputUID: "usb")
    }
    #expect(await client.unresolvedApplicationIDs() == ["a", "b8"])
    #expect(!log.entries.contains("start:a:usb"))
    #expect(!log.guardedProcessIDs.contains(9))
    #expect(log.guardedProcessIDs.contains(8))
    await client.stop()
    #expect(log.guardedProcessIDs.isEmpty)
  }

  @Test func automaticCleanupFinishesADeferredGuardOnlyAfterDemandIsRestored() async throws {
    let log = PipelineLog()
    let client = AudioMixerClient(
      automaticHealthChecks: false,
      outputGuardFactory: { _ in SlotTestOutputGuard(log: log) }
    ) {
      TestPipeline(
        $0, output: $1, source: $2, log: log, stopFailures: $0.id == "b" ? 2 : 0,
        startError: $0.id == "b" ? .unsupportedFormat : nil)
    }
    let guardID = try #require(try await client.prepareOutputSwitch(additionalProcessIDs: [1]))
    try await client.finishOutputSwitch(guardID, afterRestoring: true)
    await client.checkHealth(now: 0)
    #expect(!log.entries.contains("guard.stop"))
    let firstTarget = try target("a")
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply([firstTarget, try target("b")], outputUID: "default")
    }
    await #expect(throws: AudioControlError.unavailable) {
      try await client.apply([firstTarget], outputUID: "default")
    }
    #expect(!log.entries.contains("guard.stop"))
    let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    await client.checkHealth(now: now + 0.1)
    #expect(await client.unresolvedApplicationIDs().isEmpty)
    #expect(log.entries.contains("guard.stop"))
    await client.stop()
  }

  @Test func finishingAnOldGuardDoesNotClearANewSwitchsReservedSlots() async throws {
    let log = PipelineLog()
    let guards = SlotGuardSequence()
    let client = AudioMixerClient(
      automaticHealthChecks: false,
      outputGuardFactory: { _ in SlotTestOutputGuard(id: guards.next()) }
    ) {
      TestPipeline($0, output: $1, source: $2, log: log)
    }
    let existing = try (1...8).map { try target("b\($0)") }
    try await client.apply(existing, outputUID: "default")
    let oldGuard = try #require(try await client.prepareOutputSwitch())
    try await client.apply(existing, outputUID: "usb")
    let newGuard = try #require(try await client.prepareOutputSwitch(additionalProcessIDs: [2]))
    try await client.finishOutputSwitch(oldGuard)  // 旧操作的晚收尾不能改变新 guard 的预留。
    let extra = try target("a", output: "default")
    await #expect(throws: AudioControlError.processingLimit(8)) {
      try await client.apply(existing + [extra], outputUID: "hdmi")
    }
    #expect(await client.unresolvedApplicationIDs() == ["a"])
    #expect(log.entries.contains("start:b8:hdmi"))
    try await client.finishOutputSwitch(newGuard)
    await client.stop()
  }

  @Test func outputSwitchPreservesSlotsBeforeAdmittingANewFixedRoute() async throws {
    let log = PipelineLog()
    let client = AudioMixerClient(
      automaticHealthChecks: false, outputGuardFactory: { _ in SlotTestOutputGuard() }
    ) {
      TestPipeline($0, output: $1, source: $2, log: log)
    }
    let existing = try (1...8).map { try target("b\($0)") }
    let fixed = AudioMixTarget(
      id: "a", processObjectIDs: [2], volume: try #require(AudioAppVolume(level: 1)),
      outputUID: "default")
    try await client.apply(existing + [fixed], outputUID: "default")
    let guardID = try #require(try await client.prepareOutputSwitch(additionalProcessIDs: [2]))
    await #expect(throws: AudioControlError.processingLimit(8)) {
      try await client.apply(existing + [fixed], outputUID: "usb")
    }
    #expect(await client.unresolvedApplicationIDs() == ["a"])
    #expect(log.entries.contains("start:b8:usb"))
    #expect(!log.entries.contains("start:a:default"))
    try await client.finishOutputSwitch(guardID)
    await client.stop()
  }

  @Test(arguments: [false, true])
  func repeatedOutputSwitchesPreserveAllSlotsBeforeOrDuringRecovery(partiallyRecovered: Bool)
    async throws
  {
    let log = PipelineLog()
    let guards = SlotGuardSequence()
    let client = AudioMixerClient(
      automaticHealthChecks: false,
      outputGuardFactory: { _ in SlotTestOutputGuard(id: guards.next(), log: log) }
    ) {
      TestPipeline(
        $0, output: $1, source: $2, log: log,
        startError: $0.id == "b8" && $1 == "broken" ? .unsupportedFormat : nil)
    }
    let existing = try (1...8).map { try target("b\($0)") }
    let fixed = AudioMixTarget(
      id: "a", processObjectIDs: [9], volume: try #require(AudioAppVolume(level: 1)),
      outputUID: "default")
    try await client.apply(existing + [fixed], outputUID: "default")
    let firstGuard = try #require(try await client.prepareOutputSwitch(additionalProcessIDs: [9]))
    if partiallyRecovered {
      await #expect(throws: AudioControlError.self) {
        try await client.apply(existing + [fixed], outputUID: "broken")
      }
      #expect(await client.unresolvedApplicationIDs() == ["a", "b8"])
      #expect(!log.entries.contains("start:a:default"))
    }
    try await client.finishOutputSwitch(firstGuard, afterRestoring: true)
    let secondGuard = try #require(try await client.prepareOutputSwitch(additionalProcessIDs: [9]))
    try await client.finishOutputSwitch(firstGuard)
    await #expect(throws: AudioControlError.processingLimit(8)) {
      try await client.apply(existing + [fixed], outputUID: "usb")
    }
    #expect(await client.unresolvedApplicationIDs() == ["a"])
    #expect(log.entries.contains("start:b8:usb"))
    #expect(!log.entries.contains("start:a:default"))
    #expect(log.entries.filter { $0 == "guard.stop:101" }.count == 1)
    #expect(!log.entries.contains("guard.stop:102"))
    try await client.finishOutputSwitch(secondGuard)
    await client.stop()
    #expect(log.entries.filter { $0 == "guard.stop:102" }.count == 1)
  }

  @Test(arguments: [false, true])
  func withdrawnReservationsDoNotReturnDuringTheNextOutputSwitch(remainsInCatalog: Bool)
    async throws
  {
    let log = PipelineLog()
    let client = AudioMixerClient(
      automaticHealthChecks: false, outputGuardFactory: { _ in SlotTestOutputGuard() }
    ) {
      TestPipeline($0, output: $1, source: $2, log: log)
    }
    let existing = try (1...8).map { try target("b\($0)") }
    let newcomer = try target("z")
    try await client.apply(existing, outputUID: "default")
    let firstGuard = try #require(try await client.prepareOutputSwitch())
    var changed = Array(existing.dropFirst()) + [newcomer]
    if remainsInCatalog {
      changed.append(
        AudioMixTarget(
          id: "b1", processObjectIDs: [1], volume: try #require(AudioAppVolume(level: 1))))
    }
    try await client.apply(changed, outputUID: "usb")
    let secondGuard = try #require(try await client.prepareOutputSwitch())
    try await client.finishOutputSwitch(firstGuard)
    await #expect(throws: AudioControlError.processingLimit(8)) {
      try await client.apply(existing + [newcomer], outputUID: "hdmi")
    }
    #expect(await client.unresolvedApplicationIDs() == ["b1"])
    #expect(log.entries.contains("start:z:hdmi"))
    #expect(!log.entries.contains("start:b1:hdmi"))
    try await client.finishOutputSwitch(secondGuard)
    await client.stop()
  }

  @Test func excessiveDemandKeepsExistingPipelinesAndRecoversWhenASlotIsFreed() async throws {
    let log = PipelineLog()
    let client = AudioMixerClient(automaticHealthChecks: false) {
      TestPipeline($0, output: $1, source: $2, log: log)
    }
    let existing = try (1...8).map { try target("b\($0)") }
    try await client.apply(existing, outputUID: "default")
    let extra = try target("a")  // 排序靠前的新应用也不能挤掉已有管线。
    await #expect(throws: AudioControlError.processingLimit(8)) {
      try await client.apply(existing + [extra], outputUID: "default")
    }
    #expect(!log.entries.contains("start:a:default"))
    #expect(await client.unresolvedApplicationIDs() == ["a"])
    await #expect(throws: AudioControlError.processingLimit(8)) {
      try await client.apply(existing + [extra], outputUID: "default")
    }
    #expect(!log.entries.contains("start:a:default"))
    try await client.apply(Array(existing.dropLast()) + [extra], outputUID: "default")
    #expect(log.entries.filter { $0 == "start:a:default" }.count == 1)
    #expect(await client.unresolvedApplicationIDs().isEmpty)
    #expect(!log.entries.contains("stop:b1:default"))
    await client.stop()
  }

  @Test func aFullBatchHonorsTheBoundIncludingDuplicateIDsAndNativePassthrough() async throws {
    let log = PipelineLog()
    let client = AudioMixerClient(automaticHealthChecks: false) {
      TestPipeline($0, output: $1, source: $2, log: log)
    }
    let apps = try (1...30).map { try target(String(format: "app%02d", $0)) }
    let native = AudioMixTarget(
      id: "native", processObjectIDs: [2], volume: try #require(AudioAppVolume(level: 1)))
    await #expect(throws: AudioControlError.processingLimit(8)) {
      try await client.apply(apps + [apps[0], native], outputUID: "default")
    }
    #expect(log.entries.filter { $0.hasPrefix("start:") }.count == 8)
    #expect(await client.unresolvedApplicationIDs().count == 22)
    await client.stop()
    try await client.apply([apps.last!], outputUID: "default")
    #expect(await client.unresolvedApplicationIDs().isEmpty)
    await client.stop()
  }

  @Test func aFailedRouteStillUpdatesTheRetainedPipelinesGainWithoutRetrying() async throws {
    let log = PipelineLog()
    let client = AudioMixerClient(automaticHealthChecks: false) {
      TestPipeline(
        $0, output: $1, source: $2, log: log, startError: $1 == "usb" ? .unsupportedFormat : nil)
    }
    let a = try target("a")
    try await client.apply([a], outputUID: "default")
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply([try target("a", output: "usb")], outputUID: "default")
    }
    let muted = AudioMixTarget(
      id: "a", processObjectIDs: [1],
      volume: try #require(AudioAppVolume(level: 0.5, isMuted: true)), outputUID: "usb")
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply([muted], outputUID: "default")
    }
    #expect(log.entries.contains("volume:a:default:0.0"))
    let boosted = AudioMixTarget(
      id: "a", processObjectIDs: [1], volume: try #require(AudioAppVolume(level: 1.6)),
      outputUID: "usb")
    await #expect(throws: AudioControlError.unsupportedFormat) {
      try await client.apply([boosted], outputUID: "default")
    }
    #expect(log.entries.contains("volume:a:default:1.6"))
    #expect(log.entries.filter { $0 == "start:a:usb" }.count == 1)
    #expect(!log.entries.contains("stop:a:default"))
    await client.stop()
  }

  private func target(_ id: String, output: String? = nil) throws -> AudioMixTarget {
    AudioMixTarget(
      id: id, processObjectIDs: [1], volume: try #require(AudioAppVolume(level: 0.5)),
      outputUID: output)
  }
  @Test func replacesOnlyTheChangedApplicationAndStartsSilentlyBeforeStoppingItsOldRoute()
    async throws
  {
    let log = PipelineLog()
    let client = AudioMixerClient(automaticHealthChecks: false) {
      TestPipeline($0, output: $1, source: $2, log: log)
    }
    let a = try target("a")
    let b = try target("b")
    try await client.apply([a, b], outputUID: "default")
    try await client.apply([try target("a", output: "usb"), b], outputUID: "default")
    let events = log.entries
    #expect(events.filter { $0 == "start:b:default" }.count == 1)
    #expect(!events.contains("stop:b:default"))
    let start = try #require(events.firstIndex(of: "start:a:usb"))
    let stop = try #require(events.firstIndex(of: "stop:a:default"))
    #expect(start < stop)
    #expect(events[stop + 1] == "gain:a")
    await client.stop()
  }
  @Test func failedRetirementBlocksReplacementAndCleanupIsBounded() async throws {
    let log = PipelineLog()
    let client = AudioMixerClient(automaticHealthChecks: false) {
      TestPipeline($0, output: $1, source: $2, log: log, stopFailures: 100)
    }
    let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    try await client.apply([try target("a")], outputUID: "default")
    await client.checkHealth(now: now + 2)
    #expect(log.entries.filter { $0 == "start:a:default" }.count == 1)
    await client.checkHealth(now: now + 4)
    await client.checkHealth(now: now + 6)
    let stops = log.entries.filter { $0 == "stop:a:default" }.count
    await client.checkHealth(now: now + 8)
    #expect(log.entries.filter { $0 == "stop:a:default" }.count == stops)
    #expect(log.entries.filter { $0 == "start:a:default" }.count == 1)
    await client.stop()
  }

  @Test func removalFailureBlocksANewAppInTheSameApply() async throws {
    let log = PipelineLog()
    let client = AudioMixerClient(automaticHealthChecks: false) {
      TestPipeline($0, output: $1, source: $2, log: log, stopFailures: $0.id == "a" ? 100 : 0)
    }
    try await client.apply([try target("a")], outputUID: "default")
    await #expect(throws: AudioControlError.unavailable) {
      try await client.apply([try target("b")], outputUID: "default")
    }
    #expect(!log.entries.contains("start:b:default"))
    await client.stop()
  }
  @Test func aRetirementFailureDoesNotPreventStoppingOtherPausedApps() async throws {
    let log = PipelineLog()
    let client = AudioMixerClient(automaticHealthChecks: false) {
      TestPipeline($0, output: $1, source: $2, log: log, stopFailures: $0.id == "a" ? 100 : 0)
    }
    let a = try target("a")
    let b = try target("b")
    try await client.apply([a, b], outputUID: "default")
    try? await client.apply([b], outputUID: "default")
    try? await client.apply([], outputUID: "default")
    #expect(log.entries.contains("stop:b:default"))
    await client.stop()
  }

  @Test func aDeferredRouteChangeReplacesTheOldRouteAfterCleanup() async throws {
    let log = PipelineLog()
    let client = AudioMixerClient(automaticHealthChecks: false) {
      TestPipeline($0, output: $1, source: $2, log: log, stopFailures: $0.id == "a" ? 1 : 0)
    }
    let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    try await client.apply([try target("a"), try target("b")], outputUID: "default")
    try? await client.apply([try target("b", output: "usb")], outputUID: "default")
    #expect(!log.entries.contains("start:b:usb"))
    await client.checkHealth(now: now + 0.5)
    #expect(log.entries.contains("start:b:usb"))
    #expect(log.entries.contains("stop:b:default"))
    await client.stop()
  }
  @Test func realDeferredStartupFailureRemainsBlockedAfterItsCleanupSucceeds() async throws {
    let log = PipelineLog()
    let client = AudioMixerClient(automaticHealthChecks: false) {
      TestPipeline($0, output: $1, source: $2, log: log, stopFailures: 1, startFails: $0.id == "b")
    }
    let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    try await client.apply([try target("a")], outputUID: "default")
    try? await client.apply([try target("b")], outputUID: "default")
    await client.checkHealth(now: now + 0.5)
    #expect(log.entries.filter { $0 == "start:b:default" }.count == 1)
    await client.checkHealth(now: now + 1)
    await client.checkHealth(now: now + 2)
    #expect(log.entries.filter { $0 == "start:b:default" }.count == 1)
    await #expect(throws: AudioControlError.renderStalled) {
      try await client.apply([try target("b")], outputUID: "default")
    }
    await client.stop()
  }

  @Test func aFrozenReplacementIsReleasedAndNotRebuiltUntilExplicitRetry() async throws {
    let log = PipelineLog()
    let client = AudioMixerClient(automaticHealthChecks: false) {
      TestPipeline($0, output: $1, source: $2, log: log)
    }
    let desired = [try target("a")]
    let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    try await client.apply(desired, outputUID: "default")
    await client.checkHealth(now: now + 2)
    await client.checkHealth(now: now + 4)
    #expect(log.entries.filter { $0 == "start:a:default" }.count == 2)
    await #expect(throws: AudioControlError.renderStalled) {
      try await client.apply(desired, outputUID: "default")
    }
    #expect(await client.unresolvedApplicationIDs() == ["a"])
    #expect(log.entries.filter { $0 == "start:a:default" }.count == 2)
    await client.retryFailed()
    try await client.apply(desired, outputUID: "default")
    #expect(await client.unresolvedApplicationIDs().isEmpty)
    #expect(log.entries.filter { $0 == "start:a:default" }.count == 3)
    await client.stop()
    await client.checkHealth(now: now + 8)
    #expect(log.entries.filter { $0 == "start:a:default" }.count == 3)
  }

  @Test func aBatchFailureDoesNotMarkASuccessfulApplicationAsUnresolved() async throws {
    let log = PipelineLog()
    let client = AudioMixerClient(automaticHealthChecks: false) {
      TestPipeline($0, output: $1, source: $2, log: log, startFails: $0.id == "a")
    }
    await #expect(throws: AudioControlError.renderStalled) {
      try await client.apply(
        [try target("a"), try target("b", output: "usb")], outputUID: "default")
    }
    #expect(await client.unresolvedApplicationIDs() == ["a"])
    #expect(log.entries.contains("start:b:usb"))
    await client.stop()
  }
}
