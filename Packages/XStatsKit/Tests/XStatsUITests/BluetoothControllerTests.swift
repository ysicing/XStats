// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import Metrics
import Testing
@testable import XStatsUI

@MainActor
struct BluetoothControllerTests {
  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
  }

  @Test func connectionBurstsAreCoalescedAndRateLimited() async throws {
    let events = BluetoothConnectionEventsFixture()
    let controller = BluetoothController(
      events: events, eventDelay: .milliseconds(20), minimumEventInterval: .milliseconds(100))
    var starts: [ContinuousClock.Instant] = []
    controller.readDevices = {
      starts.append(.now)
      return []
    }
    defer { controller.stop() }
    controller.setDemand(.foreground)
    try await waitUntil { starts.count == 1 && !controller.isReading }
    let staleCallback = try #require(events.onChange)
    for _ in 0..<50 { events.onChange?() }
    try await waitUntil { starts.count == 2 && !controller.isReading }
    #expect(starts[0].duration(to: starts[1]) >= .milliseconds(100))
    for _ in 0..<50 { events.onChange?() }
    try await waitUntil { starts.count == 3 && !controller.isReading }
    #expect(starts[1].duration(to: starts[2]) >= .milliseconds(100))
    controller.setDemand(.off)
    staleCallback()
    controller.refresh()
    // 显式手动读取仍可在无持续需求时执行，但旧连接回调不能恢复轮询。
    try await waitUntil { starts.count == 4 && !controller.isReading }
    try await Task.sleep(for: .milliseconds(150))
    #expect(starts.count == 4)
    #expect(events.starts == 1 && events.stops == 1)
  }

  @Test func eventDuringAReadQueuesOnlyOneFreshFollowUp() async throws {
    let events = BluetoothConnectionEventsFixture()
    let controller = BluetoothController(
      events: events, eventDelay: .milliseconds(10), minimumEventInterval: .zero)
    let gates = [BluetoothReadGate(), BluetoothReadGate()]
    var reads = 0
    controller.readDevices = {
      let index = reads
      reads += 1
      if index < gates.count { await gates[index].wait() }
      return []
    }
    defer { controller.stop() }
    controller.setDemand(.foreground)
    await gates[0].waitUntilStarted()
    for _ in 0..<30 { events.onChange?() }
    try await Task.sleep(for: .milliseconds(40))
    #expect(reads == 1)
    await gates[0].release()
    await gates[1].waitUntilStarted()
    #expect(reads == 2)
    await gates[1].release()
    try await waitUntil { !controller.isReading }
    try await Task.sleep(for: .milliseconds(40))
    #expect(reads == 2)
  }

  @Test func closeAndReopenWaitForCancelledReadAndRejectItsResult() async throws {
    let events = BluetoothConnectionEventsFixture()
    let controller = BluetoothController(events: events, eventDelay: .milliseconds(10))
    let gates = [BluetoothReadGate(), BluetoothReadGate()]
    var reads = 0
    var cancelledReads = 0
    controller.readDevices = {
      let index = reads
      reads += 1
      if index < gates.count { await gates[index].wait() }
      if Task.isCancelled { cancelledReads += 1 }
      return [
        BluetoothDevice(
          name: "Read \(index)", address: "AA:BB:CC:DD:EE:FF", kind: .keyboard,
          batteries: [("Battery", 50)])
      ]
    }
    defer { controller.stop() }
    controller.setDemand(.foreground)
    await gates[0].waitUntilStarted()
    let staleCallback = try #require(events.onChange)
    events.onChange?()
    controller.setDemand(.off)
    controller.setDemand(.foreground)
    staleCallback()
    try await Task.sleep(for: .milliseconds(40))
    #expect(reads == 1)
    await gates[0].release()
    await gates[1].waitUntilStarted()
    #expect(controller.devices == nil && controller.updatedAt == nil)
    #expect(cancelledReads == 1)
    await gates[1].release()
    try await waitUntil { controller.devices?.first?.name == "Read 1" }
    try await Task.sleep(for: .milliseconds(40))
    #expect(reads == 2)
    #expect(events.starts == 2 && events.stops == 1)
  }

  @Test func pauseDropsPendingEventsAndWakeRestoresLatestDemandOnce() async throws {
    let events = BluetoothConnectionEventsFixture()
    let controller = BluetoothController(
      events: events, eventDelay: .milliseconds(20), minimumEventInterval: .zero)
    var reads = 0
    controller.readDevices = {
      reads += 1
      return []
    }
    defer { controller.stop() }
    controller.setDemand(.foreground)
    try await waitUntil { reads == 1 && !controller.isReading }
    events.onChange?()
    controller.setPaused(true)
    controller.setPaused(true)
    controller.setDemand(.background)
    controller.refresh()
    _ = await controller.recentDevices(maxAge: 0)
    try await Task.sleep(for: .milliseconds(60))
    #expect(reads == 1)
    #expect(events.starts == 1 && events.stops == 1)
    controller.setPaused(false)
    controller.setPaused(false)
    try await waitUntil { reads == 2 && !controller.isReading }
    controller.setDemand(.foreground)
    try await Task.sleep(for: .milliseconds(60))
    #expect(reads == 2)
    #expect(events.starts == 2)
    controller.stop()
    controller.refresh()
    _ = await controller.recentDevices(maxAge: 0)
    #expect(reads == 2)
    #expect(events.stops == 2)
  }

  @Test func failedEventRegistrationKeepsOnDemandReadsAndFallbackIntervals() async throws {
    let events = BluetoothConnectionEventsFixture(available: false)
    let controller = BluetoothController(events: events)
    var reads = 0
    controller.readDevices = {
      reads += 1
      return []
    }
    defer { controller.stop() }
    controller.setDemand(.background)
    try await waitUntil { reads == 1 && !controller.isReading }
    #expect(BluetoothController.Demand.background.interval == .seconds(300))
    #expect(BluetoothController.Demand.foreground.interval == .seconds(60))
    #expect(events.onChange == nil)
    controller.refresh()
    try await waitUntil { reads == 2 && !controller.isReading }
  }

  @Test func releasingIdleControllerStopsObservation() async throws {
    let events = BluetoothConnectionEventsFixture()
    var controller: BluetoothController? = BluetoothController(events: events)
    let isReleased = { [weak controller] in controller == nil }
    controller?.readDevices = { [] }
    controller?.setDemand(.foreground)
    try await waitUntil { controller?.updatedAt != nil && controller?.isReading == false }
    controller = nil
    try await waitUntil { isReleased() && events.stops == 1 }
  }

  @Test func releasingControllerDuringAnEventFollowUpCancelsTheRead() async throws {
    let events = BluetoothConnectionEventsFixture()
    let gate = BluetoothReadGate()
    var wasCancelled = false
    var controller: BluetoothController? = BluetoothController(
      events: events, eventDelay: .milliseconds(10))
    let isReleased = { [weak controller] in controller == nil }
    controller?.readDevices = {
      await gate.wait()
      wasCancelled = Task.isCancelled
      return []
    }
    defer { Task { await gate.release() } }
    controller?.setDemand(.foreground)
    await gate.waitUntilStarted()
    events.onChange?()
    try await Task.sleep(for: .milliseconds(40))
    controller = nil
    try await waitUntil { isReleased() && events.stops == 1 }
    await gate.release()
    try await waitUntil { wasCancelled }
  }

  @Test func concurrentRequestsWaitForTheSameFreshRead() async {
    let controller = BluetoothController()
    let gate = BluetoothReadGate()
    var reads = 0
    controller.readDevices = {
      reads += 1
      await gate.wait()
      return [
        BluetoothDevice(
          name: "Keyboard", address: "fixture", kind: .keyboard,
          batteries: [("Battery", 10)])
      ]
    }
    let first = Task { await controller.recentDevices(maxAge: 300) }
    await gate.waitUntilStarted()
    #expect(controller.isReading)
    // 第二个请求进入时采样仍被 gate 阻塞，必须等待同一次采样，不能返回空缓存。
    let release = Task { await gate.release() }
    let secondDevices = await controller.recentDevices(maxAge: 300)
    await release.value
    let firstDevices = await first.value
    #expect(firstDevices.map(\.name) == ["Keyboard"])
    #expect(secondDevices.map(\.id) == firstDevices.map(\.id))
    #expect(reads == 1)
    #expect(!controller.isReading)
    let cached = await controller.recentDevices(maxAge: 300)
    #expect(cached.map(\.id) == firstDevices.map(\.id))
    #expect(reads == 1)
    _ = await controller.recentDevices(maxAge: 300, now: Date().addingTimeInterval(301))
    #expect(reads == 2)
  }
}

@MainActor
private final class BluetoothConnectionEventsFixture: BluetoothConnectionObserving {
  var onChange: (@MainActor () -> Void)?
  var starts = 0
  var stops = 0
  let available: Bool

  init(available: Bool = true) { self.available = available }

  func start(onChange: @escaping @MainActor () -> Void) -> Bool {
    starts += 1
    if available { self.onChange = onChange }
    return available
  }

  func stop() {
    if onChange != nil { stops += 1 }
    onChange = nil
  }
}

private actor BluetoothReadGate {
  private var started: CheckedContinuation<Void, Never>?
  private var blocked: CheckedContinuation<Void, Never>?
  private var didStart = false
  private var released = false

  func wait() async {
    if released { return }
    didStart = true
    started?.resume()
    started = nil
    await withCheckedContinuation { blocked = $0 }
  }

  func waitUntilStarted() async {
    if didStart { return }
    await withCheckedContinuation { started = $0 }
  }

  func release() {
    released = true
    blocked?.resume()
    blocked = nil
  }
}
