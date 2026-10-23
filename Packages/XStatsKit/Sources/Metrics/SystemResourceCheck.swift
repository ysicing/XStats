// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct SustainedCPUUsage: Sendable {
  public let family: String
  public let firstCPU: Double
  public let secondCPU: Double
  public let pids: [Int32]
}

public struct SystemResourceReport: Sendable {
  public let cpu: [SustainedCPUUsage]
  public let cpuComplete: Bool
  public let firstMemory: MemoryUsage?
  public let memory: MemoryUsage?
  public let topMemory: [ProcessUsage]
  public let disk: DiskUsage?
  public let uptime: TimeInterval
  public let interval: TimeInterval
}

public enum SystemResourceCheck {
  /// 独立的短期采样器不改变 MetricsHub 的其他需求，也不遗留常驻计时器。
  @concurrent
  public static func sample() async throws -> SystemResourceReport {
    var sampler = ProcessSampler()
    _ = sampler.sample(includeSystem: true)
    var complete = sampler.systemSampleSucceeded
    try Task.checkCancellation()
    try await Task.sleep(for: .seconds(1))
    let first = sampler.sample(includeSystem: true)
    complete = complete && sampler.systemSampleSucceeded
    let memory = MemorySampler()
    let beforeMemory = memory.sample()
    let started = ContinuousClock.now
    try Task.checkCancellation()
    try await Task.sleep(for: .seconds(1))
    let second = sampler.sample(includeSystem: true)
    complete = complete && sampler.systemSampleSucceeded
    try Task.checkCancellation()
    let interval = ContinuousClock.now - started
    return SystemResourceReport(
      cpu: evaluateCPU(first: first, second: second),
      cpuComplete: complete && !first.isEmpty && !second.isEmpty,
      firstMemory: beforeMemory, memory: memory.sample(),
      topMemory: Array(second.sorted { $0.memory > $1.memory }.prefix(5)),
      disk: DiskSampler.sample(), uptime: ProcessInfo.processInfo.systemUptime,
      interval: Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
    )
  }

  public static func evaluateCPU(
    first: [ProcessUsage], second: [ProcessUsage]
  ) -> [SustainedCPUUsage] {
    let previous = Dictionary(first.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    var families: [String: (Double, Double, [Int32])] = [:]
    for process in second {
      guard let before = previous[process.pid], before.name == process.name,
        before.executablePath == process.executablePath, process.cpuTime >= before.cpuTime,
        before.cpu.isFinite, process.cpu.isFinite
      else { continue }
      let family = family(for: process.name) ?? process.name + " (PID \(process.pid))"
      var aggregate = families[family] ?? (0, 0, [])
      aggregate.0 += max(0, before.cpu)
      aggregate.1 += max(0, process.cpu)
      aggregate.2.append(process.pid)
      families[family] = aggregate
    }
    return families.compactMap { name, values in
      guard values.0 >= 0.25, values.1 >= 0.25 else { return nil }
      return SustainedCPUUsage(
        family: name, firstCPU: values.0, secondCPU: values.1, pids: values.2.sorted())
    }.sorted { $0.secondCPU == $1.secondCPU ? $0.family < $1.family : $0.secondCPU > $1.secondCPU }
  }

  public static func memoryNeedsAttention(first: MemoryUsage, second: MemoryUsage) -> Bool {
    first.pressure != .normal || second.pressure != .normal
  }

  private static func family(for name: String) -> String? {
    if ["mds", "mds_stores", "mdbulkimport"].contains(name) || name.hasPrefix("mdworker") {
      return "Spotlight"
    }
    if ["CloudShell", "AliEntSafe", "aliEDR"].contains(name) {
      return "CloudShell / AliEntSafe / aliEDR"
    }
    if ["diskimagesiod", "simdiskimaged"].contains(name) { return "CoreSimulator" }
    if ["WindowServer", "syspolicyd"].contains(name) { return name }
    return nil
  }
}
