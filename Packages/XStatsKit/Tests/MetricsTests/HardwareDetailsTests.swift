// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics

struct HardwareDetailsTests {
  @Test func gpuResidencyIgnoresInvalidAndIdleStates() {
    let states: [(name: String, residency: Int64)] = [
      ("OFF", 900), ("P1", 100), ("P2", 100),
      ("P-1", 200), ("P9", 100), ("P0", 500), ("P2", -20),
    ]
    #expect(PowerSampler.gpuFrequency(states, table: [0, 600, 1200]) == 900)
    #expect(PowerSampler.gpuFrequency([("OFF", 900)], table: [0, 600]) == nil)
  }

  @Test func gpuTablesRequireOffStateAndSaneUnits() {
    func table(_ values: [UInt32]) -> Data {
      var data = Data()
      for value in values {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(800).littleEndian) { data.append(contentsOf: $0) }
      }
      return data
    }
    #expect(
      PowerSampler.parseGPUFrequencyTable(table([0, 600_000_000, 1_200_000_000])) == [0, 600, 1200])
    #expect(PowerSampler.parseGPUFrequencyTable(table([0, 600, 1200])) == [0, 600, 1200])
    #expect(PowerSampler.parseGPUFrequencyTable(table([600, 1200])) == nil)
    #expect(PowerSampler.parseGPUFrequencyTable(Data([0, 1, 2])) == nil)
  }

  @Test func gpuDetailsPreserveMissingFieldsAndBoundUtilization() throws {
    let gpu = try #require(
      GPUSampler.usage(
        name: "GPU", coreCount: 8,
        statistics: [
          "Device Utilization %": 25, "Renderer Utilization %": 150, "Tiler Utilization %": -5,
          "In use system memory": 4096,
        ]))
    #expect(gpu.utilization == 0.25 && gpu.rendererUtilization == 1 && gpu.tilerUtilization == 0)
    #expect(gpu.memoryInUse == 4096)
    let missing = try #require(
      GPUSampler.usage(name: "GPU", coreCount: nil, statistics: ["Device Utilization %": 0]))
    #expect(missing.rendererUtilization == nil && missing.memoryInUse == nil)
    #expect(GPUSampler.usage(name: "GPU", coreCount: nil, statistics: [:]) == nil)
  }

  @Test func batteryUsesNominalCapacityAndSignedCurrent() {
    var status = BatteryStatus(
      level: 0.5, isCharging: false, isPluggedIn: false, isFullyCharged: false)
    BatterySampler.applyRegistryDetails(
      [
        "BatteryData": [
          "DesignCapacity": 5000, "NominalChargeCapacity": 4500,
          "FullChargeCapacity": 4600,
        ], "Voltage": 12000, "InstantAmperage": NSNumber(value: UInt64.max - 999),
      ], to: &status)
    #expect(
      status.designCapacity == 5000 && status.fullChargeCapacity == 4500 && status.health == 0.9)
    #expect(status.voltage == 12 && status.amperage == -1)
    BatterySampler.applyRegistryDetails(
      [
        "BatteryData": ["DesignCapacity": 0, "FullChargeCapacity": -1],
        "Voltage": -5,
      ], to: &status)
    #expect(status.designCapacity == nil && status.fullChargeCapacity == nil)
    #expect(status.health == nil && status.voltage == nil && status.amperage == nil)
  }

  @Test func diskCompositionAccountsForEveryByteAndRejectsInconsistentReadings() throws {
    let b = try #require(
      DiskBreakdown.compose(
        total: 1000, free: 200, purgeable: 100,
        systemUsed: 100, dataUsed: 500, vmUsed: 50))
    #expect(b.system == 100 && b.data == 400 && b.virtualMemory == 50 && b.other == 150)
    #expect(b.system + b.data + b.virtualMemory + b.other + b.purgeable + b.free == 1000)
    #expect(
      DiskBreakdown.compose(
        total: 100, free: 20, purgeable: 0,
        systemUsed: 50, dataUsed: 50, vmUsed: 0) == nil)
    #expect(
      DiskBreakdown.compose(
        total: .max, free: 0, purgeable: 0,
        systemUsed: .max, dataUsed: .max, vmUsed: 1) == nil)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_DISK_DETAILS_REPORT"] != nil))
  func realDiskCompositionIsReadableAndBounded() throws {
    let path = try #require(ProcessInfo.processInfo.environment["XSTATS_DISK_DETAILS_REPORT"])
    let start = ProcessInfo.processInfo.systemUptime
    let summary = try #require(DiskSampler.sample())
    let summarySeconds = ProcessInfo.processInfo.systemUptime - start
    let detailsStart = ProcessInfo.processInfo.systemUptime
    let detailed = try #require(DiskSampler.sample(includeBreakdown: true))
    let detailsSeconds = ProcessInfo.processInfo.systemUptime - detailsStart
    #expect(summary.breakdown == nil)
    var report: [String: Double] = [
      "summarySeconds": summarySeconds, "detailsSeconds": detailsSeconds,
      "totalBytes": Double(detailed.total),
    ]
    if let b = detailed.breakdown {
      #expect(
        b.system + b.data + b.virtualMemory + b.other + b.purgeable + b.free == detailed.total)
      report["systemBytes"] = Double(b.system)
      report["dataBytes"] = Double(b.data)
      report["vmBytes"] = Double(b.virtualMemory)
      report["otherBytes"] = Double(b.other)
      report["purgeableBytes"] = Double(b.purgeable)
      report["freeBytes"] = Double(b.free)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: path))
  }

}
