// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import NetworkObservation
@testable import XStatsUI

struct NetworkTrafficHistoryTests {
  private let start = Date(timeIntervalSince1970: 100)

  private func record(_ name: String = "Browser") -> ObservedConnection {
    ObservedConnection(
      id: UUID(), timestamp: start, processID: 42,
      executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
      address: "203.0.113.1", hostname: "example.test", port: 443,
      transport: .tcp, direction: .outbound)
  }

  private func snapshot(_ record: ObservedConnection, seconds: Double, bytes: UInt64)
    -> ConnectionTrafficSnapshot
  {
    .init(
      id: record.id, timestamp: start.addingTimeInterval(seconds),
      receivedBytes: bytes, sentBytes: bytes / 2)
  }

  @Test func ratesUseElapsedTimeAndApplicationSelection() throws {
    var history = NetworkTrafficHistory()
    let first = record()
    let second = record("Other")
    history.observe(first, snapshot: snapshot(first, seconds: 0, bytes: 0))
    history.observe(second, snapshot: snapshot(second, seconds: 0, bytes: 0))
    history.observe(first, snapshot: snapshot(first, seconds: 5, bytes: 5000))
    history.observe(second, snapshot: snapshot(second, seconds: 5, bytes: 20000))
    let points = history.points(
      interval: 60, matching: { $0.applicationName == "Browser" },
      now: start.addingTimeInterval(5))
    let point = try #require(points.last { $0.receivedBytesPerSecond != nil })
    #expect(point.receivedBytesPerSecond == 1000)
    #expect(point.sentBytesPerSecond == 500)
  }

  @Test func pauseAndCounterRollbackNeverProduceSpikes() {
    var history = NetworkTrafficHistory()
    let flow = record()
    history.observe(flow, snapshot: snapshot(flow, seconds: 0, bytes: 0))
    history.observe(flow, snapshot: snapshot(flow, seconds: 5, bytes: 5000))
    history.pause(at: start.addingTimeInterval(10))
    history.observe(flow, snapshot: snapshot(flow, seconds: 60, bytes: 900_000))
    history.observe(flow, snapshot: snapshot(flow, seconds: 65, bytes: 905_000))
    history.observe(flow, snapshot: snapshot(flow, seconds: 70, bytes: 10))
    let points = history.points(
      interval: 120, matching: { _ in true }, now: start.addingTimeInterval(70))
    #expect(points.contains { $0.receivedBytesPerSecond == nil })
    #expect(points.compactMap(\.receivedBytesPerSecond).allSatisfy { $0 <= 1000 })
    #expect(Set(points.filter { $0.receivedBytesPerSecond != nil }.map(\.segment)).count == 2)
  }

  @Test func duplicateSnapshotsAndLongGapsAreNotCountedAgain() {
    var history = NetworkTrafficHistory()
    let flow = record()
    history.observe(flow, snapshot: snapshot(flow, seconds: 0, bytes: 0))
    history.observe(flow, snapshot: snapshot(flow, seconds: 5, bytes: 5000))
    history.observe(flow, snapshot: snapshot(flow, seconds: 5, bytes: 5000))
    history.observe(flow, snapshot: snapshot(flow, seconds: 120, bytes: 900_000))
    #expect(history.sampleCount == 1)
  }

  @Test func unreadOpenEventCannotRestoreTheBaselineAcrossPause() {
    var history = NetworkTrafficHistory()
    var flow = record()
    flow.traffic = snapshot(flow, seconds: 0, bytes: 0)
    history.pause(at: start.addingTimeInterval(2))
    var resumed = ObservationBatch(
      epoch: UUID().uuidString, cursor: 1, discarded: 0, events: [flow])
    resumed.activeIDs = [flow.id]
    resumed.traffic = []
    history.accept(resumed, records: [flow])
    resumed = ObservationBatch(
      epoch: resumed.epoch, cursor: 1, discarded: 0, events: [])
    resumed.activeIDs = [flow.id]
    resumed.traffic = [snapshot(flow, seconds: 7, bytes: 7000)]
    history.accept(resumed, records: [flow])
    #expect(history.sampleCount == 0)
    resumed.traffic = [snapshot(flow, seconds: 12, bytes: 12_000)]
    history.accept(resumed, records: [flow])
    #expect(history.sampleCount == 1)
  }

  @Test func historyBoundsMemoryAndClearsAllBaselines() {
    var history = NetworkTrafficHistory()
    let flow = record()
    for seconds in 0...10_000 {
      history.observe(
        flow, snapshot: snapshot(flow, seconds: Double(seconds), bytes: UInt64(seconds)))
    }
    #expect(history.sampleCount <= NetworkTrafficHistory.maximumSamples)
    history.clear()
    #expect(history.sampleCount == 0)
    history.observe(flow, snapshot: snapshot(flow, seconds: 10_001, bytes: 1_000_000))
    #expect(history.sampleCount == 0)
  }

  @Test func closeInTheNextBatchStillCountsAShortInactiveFlow() {
    var history = NetworkTrafficHistory()
    var flow = record()
    flow.traffic = snapshot(flow, seconds: 0, bytes: 0)
    var opening = ObservationBatch(
      epoch: UUID().uuidString, cursor: 64, discarded: 0, events: [flow])
    opening.activeIDs = []
    history.accept(opening, records: [flow])
    flow.closedAt = start.addingTimeInterval(5)
    flow.traffic = snapshot(flow, seconds: 5, bytes: 5000)
    var closing = ObservationBatch(
      epoch: opening.epoch, cursor: 65, discarded: 0, events: [flow])
    closing.activeIDs = []
    history.accept(closing, records: [flow])
    #expect(history.sampleCount == 1)
  }

  @Test func manyConcurrentFlowsKeepAFixedWindowAndClearIt() {
    var history = NetworkTrafficHistory()
    let flows = (0..<512).map { _ in record() }
    for step in 0..<20 {
      for flow in flows {
        history.observe(
          flow, snapshot: snapshot(flow, seconds: Double(step * 5), bytes: UInt64(step * 5000)))
      }
    }
    #expect(history.sampleCount == NetworkTrafficHistory.maximumSamples)
    let points = history.points(
      interval: 900, matching: { _ in true }, now: start.addingTimeInterval(95))
    #expect(points.count == 180)
    #expect(points.compactMap(\.receivedBytesPerSecond).allSatisfy { $0 <= 512_000 })
    history.clear()
    #expect(history.sampleCount == 0)
    #expect(
      history.points(interval: 900, matching: { _ in true }).allSatisfy {
        $0.receivedBytesPerSecond == nil
      })
  }
}
