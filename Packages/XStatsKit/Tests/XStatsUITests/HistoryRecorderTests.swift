// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics
@testable import XStatsUI

@Suite @MainActor struct HistoryRecorderTests {
  @Test func flushAndWaitPreservesSameMinuteSamples() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "HistoryRecorderTests.\(UUID())"
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: suite)))
    settings.historyEnabled = true
    let recorder = HistoryRecorder(
      settings: settings, databaseURL: root.appendingPathComponent("history.sqlite"))
    let database = try #require(recorder.database)
    let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
    var snapshot = MetricsSnapshot()
    for (offset, cpu) in [(0.0, 0.9), (10.0, 0.3), (30.0, 0.0)] {
      snapshot.date = base.addingTimeInterval(offset)
      snapshot.cpu = CPULoad(total: cpu, user: cpu, system: 0, perCore: [], loadAverage: [])
      recorder.record(snapshot)
      recorder.flush()
    }
    await recorder.flushAndWait()
    let points = await database.query(from: base, to: base.addingTimeInterval(60), bucket: 60)
    let point = try #require(points.first)
    #expect(points.count == 1)
    #expect(abs((point.cpu ?? 0) - 0.4) < 1e-9 && point.cpuMax == 0.9)
  }

  @Test func flushAndWaitIncludesRolloverAndFinalMinute() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "HistoryRecorderTests.\(UUID())"
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: suite)))
    settings.historyEnabled = true
    let recorder = HistoryRecorder(
      settings: settings, databaseURL: root.appendingPathComponent("history.sqlite"))
    let database = try #require(recorder.database)
    let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60 - 120)
    var snapshot = MetricsSnapshot()
    for minute in 0..<3 {
      let cpu = Double(minute + 1) / 10
      snapshot.date = base.addingTimeInterval(Double(minute) * 60)
      snapshot.cpu = CPULoad(total: cpu, user: cpu, system: 0, perCore: [], loadAverage: [])
      recorder.record(snapshot)
    }
    await recorder.flushAndWait()
    let points = await database.query(from: base, to: base.addingTimeInterval(180), bucket: 60)
    #expect(points.map(\.cpu) == [0.1, 0.2, 0.3])
    await recorder.flushAndWait()
    #expect(await database.count() == 3)
  }

  @Test func clearRunsAfterQueuedWritesAndBeforeNewSamples() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "HistoryRecorderTests.\(UUID())"
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: suite)))
    settings.historyEnabled = true
    let recorder = HistoryRecorder(
      settings: settings, databaseURL: root.appendingPathComponent("history.sqlite"))
    let database = try #require(recorder.database)
    let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
    var snapshot = MetricsSnapshot()
    snapshot.date = base
    snapshot.cpu = CPULoad(total: 0.9, user: 0.9, system: 0, perCore: [], loadAverage: [])
    recorder.record(snapshot)
    recorder.flush()
    recorder.clear()
    snapshot.date = base.addingTimeInterval(30)
    snapshot.cpu?.total = 0.1
    recorder.record(snapshot)
    await recorder.flushAndWait()
    let points = await database.query(from: base, to: base.addingTimeInterval(60), bucket: 60)
    #expect(points.count == 1)
    #expect(points.first?.cpu == 0.1 && points.first?.cpuMax == 0.1)
  }
}
