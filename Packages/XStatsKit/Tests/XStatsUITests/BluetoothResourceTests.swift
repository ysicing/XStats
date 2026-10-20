// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Testing
@testable import XStatsUI

/// 使用真实电量读取，对比同一负载下的读取次数与关闭后的行为；不改变系统蓝牙连接。
@MainActor
struct BluetoothResourceTests {
  private struct Phase: Codable {
    let name: String
    let elapsedSeconds: Double
    let cpuSeconds: Double
    let reads: Int
    let publishedAfterClose: Bool
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["XSTATS_BLUETOOTH_RESOURCE_REPORT"] != nil))
  func realReadsReturnToIdle() async throws {
    let output = try #require(
      ProcessInfo.processInfo.environment["XSTATS_BLUETOOTH_RESOURCE_REPORT"])
    let controller = BluetoothController()
    let read = controller.readDevices
    var reads = 0
    controller.readDevices = {
      reads += 1
      return await read()
    }
    defer { controller.setDemand(.off) }
    var phases: [Phase] = []
    for name in ["idle", "foreground", "burst", "close-during-read", "closed"] {
      let started = ContinuousClock.now
      let cpu = Self.cpuTime()
      let before = reads
      var closedAt: Date?
      switch name {
      case "foreground": controller.setDemand(.foreground)
      case "burst":
        for _ in 0..<30 { controller.refresh() }
      case "close-during-read":
        controller.refresh()
        let deadline = ContinuousClock.now + .seconds(20)
        while !controller.isReading, ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(10))
        }
        try #require(controller.isReading)
        closedAt = controller.updatedAt
        controller.setDemand(.off)
      default: break
      }
      // 先给真实子进程启动机会；再等待本阶段读取或取消完成。
      try await Task.sleep(for: .seconds(2))
      let deadline = ContinuousClock.now + .seconds(20)
      while controller.isReading, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      try #require(!controller.isReading)
      phases.append(
        Phase(
          name: name, elapsedSeconds: Self.seconds(started.duration(to: .now)),
          cpuSeconds: Self.cpuTime() - cpu, reads: reads - before,
          publishedAfterClose: name == "close-during-read" && controller.updatedAt != closedAt))
      if name == "idle" || name == "closed" { #expect(reads == before) }
      if name == "foreground" || name == "burst" { #expect(reads - before == 1) }
      if name == "close-during-read" { #expect(controller.updatedAt == closedAt) }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(phases).write(to: URL(fileURLWithPath: output))
  }

  private static func cpuTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }

  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
