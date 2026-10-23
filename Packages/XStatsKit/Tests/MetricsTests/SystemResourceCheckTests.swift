// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics

struct SystemResourceCheckTests {
  @Test func cpuRequiresTwoValidIntervalsAndMatchingProcessIdentity() {
    let before = process(pid: 10, name: "WindowServer", cpu: 0.5, time: 20)
    let after = process(pid: 10, name: "WindowServer", cpu: 0.6, time: 21)
    let result = SystemResourceCheck.evaluateCPU(first: [before], second: [after])
    #expect(result.count == 1)
    #expect(result.first?.family == "WindowServer")
    #expect(SystemResourceCheck.evaluateCPU(first: [], second: [after]).isEmpty)
    var reusedPID = after
    reusedPID.cpuTime = 1
    #expect(SystemResourceCheck.evaluateCPU(first: [before], second: [reusedPID]).isEmpty)
  }

  @Test func cpuIgnoresSpikesAndAggregatesKnownFamilies() {
    let first = [
      process(pid: 1, name: "mds", cpu: 0.15, time: 10),
      process(pid: 2, name: "mdworker_shared", cpu: 0.15, time: 10),
      process(pid: 3, name: "compiler", cpu: 0.9, time: 10),
    ]
    let second = [
      process(pid: 1, name: "mds", cpu: 0.2, time: 11),
      process(pid: 2, name: "mdworker_shared", cpu: 0.2, time: 11),
      process(pid: 3, name: "compiler", cpu: 0.1, time: 11),
    ]
    let findings = SystemResourceCheck.evaluateCPU(first: first, second: second)
    #expect(findings.map(\.family) == ["Spotlight"])
    #expect(abs((findings.first?.secondCPU ?? 0) - 0.4) < 0.0001)
  }

  @Test func swapOccupancyAloneDoesNotMeanMemoryPressure() {
    let first = memory(pressure: .normal, swapUsed: 8_000_000_000, swapOut: 100)
    let second = memory(pressure: .normal, swapUsed: 8_000_000_000, swapOut: 100)
    #expect(SystemResourceCheck.memoryNeedsAttention(first: first, second: second) == false)
    #expect(
      SystemResourceCheck.memoryNeedsAttention(
        first: first, second: memory(pressure: .warning, swapUsed: 0, swapOut: 100)))
  }

  private func process(pid: Int32, name: String, cpu: Double, time: Double) -> ProcessUsage {
    var result = ProcessUsage(
      pid: pid, name: name, executablePath: "/usr/bin/" + name, appBundlePath: nil,
      cpu: cpu, memory: 0)
    result.cpuTime = time
    return result
  }

  private func memory(pressure: MemoryPressure, swapUsed: UInt64, swapOut: UInt64) -> MemoryUsage {
    MemoryUsage(
      total: 16_000_000_000, app: 4_000_000_000, wired: 1_000_000_000,
      compressed: 0, cached: 0, swapUsed: swapUsed, swapTotal: 10_000_000_000,
      pressure: pressure, uncompressed: 0, swapInBytes: 0, swapOutBytes: swapOut)
  }
}
