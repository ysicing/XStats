// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import Metrics
import Testing
@testable import XStatsUI

@MainActor
struct BluetoothControllerTests {
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
