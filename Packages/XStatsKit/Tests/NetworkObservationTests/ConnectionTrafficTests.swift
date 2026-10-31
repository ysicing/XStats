// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import NetworkObservation

struct ConnectionTrafficTests {
  @Test func legacyActivityWindowDoesNotLimitJournalCaptureOrNewClientDelivery() throws {
    let buffer = ObservationBuffer()
    _ = buffer.read(after: 0, epoch: "", now: 1, legacy: true)
    let records = (0..<2048).map { _ in connection() }
    for record in records { #expect(buffer.record(record, now: 2)) }
    let legacy = buffer.read(after: 0, epoch: "", now: 3, legacy: true)
    #expect(legacy.protocolVersion == 2)
    #expect(legacy.activeIDs?.count == 512)
    #expect(try JSONEncoder().encode(legacy).count <= ObservationLimits.maximumPayloadBytes)
    var cursor: Int64 = 0
    var epoch = ""
    var delivered: Set<UUID> = []
    while true {
      let batch = buffer.read(after: cursor, epoch: epoch, now: 4)
      #expect(batch.protocolVersion == 3 && batch.activeIDs == nil)
      #expect(batch.discarded == 0 && batch.captureDropped == 0)
      delivered.formUnion(batch.events.map(\.id))
      cursor = batch.cursor
      epoch = batch.epoch
      if batch.events.count < ObservationLimits.batchCount { break }
    }
    #expect(delivered == Set(records.map(\.id)))
  }

  @Test func finishingSealsNewAndCloseEventsWithoutDiscardingTheTail() {
    let buffer = ObservationBuffer()
    _ = buffer.read(after: 0, epoch: "", now: 1)
    let flow = connection()
    buffer.record(flow, now: 2)
    buffer.updateTraffic(flow.id, receivedBytes: 1000, sentBytes: 500, now: 3)
    let tail = buffer.read(after: 0, epoch: "", now: 4, renewLease: false)
    #expect(tail.events.count == 2)
    #expect(!buffer.isObserving(now: 4))
    #expect(!buffer.record(connection(), now: 4))
    buffer.close(flow.id, receivedBytes: 2000, sentBytes: 1000, now: 4)
    #expect(
      buffer.read(after: tail.cursor, epoch: tail.epoch, now: 5, renewLease: false).events.isEmpty)
  }
  private func connection() -> ObservedConnection {
    ObservedConnection(
      id: UUID(), timestamp: Date(timeIntervalSince1970: 100),
      processID: 42, executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
      address: "203.0.113.10", hostname: nil, port: 443,
      transport: .tcp, direction: .outbound)
  }

  @Test func everyStatisticsIntervalIsDeliveredUntilPersistenceAcknowledgesIt() {
    let buffer = ObservationBuffer()
    _ = buffer.read(after: 0, epoch: "", now: 1)
    let record = connection()
    buffer.record(record, now: 2)
    for count in 1...300 {
      buffer.updateTraffic(
        record.id, receivedBytes: UInt64(count), sentBytes: UInt64(count * 2),
        at: Date(timeIntervalSince1970: Double(count + 100)), now: 3)
    }
    var cursor: Int64 = 0
    var epoch = ""
    var received: [UInt64] = []
    while true {
      let batch = buffer.read(after: cursor, epoch: epoch, now: 4)
      #expect(batch.discarded == 0)
      let retry = buffer.read(after: cursor, epoch: epoch, now: 4)
      #expect(retry.events == batch.events)
      received += batch.events.compactMap { $0.traffic?.receivedBytes }
      cursor = batch.cursor
      epoch = batch.epoch
      if batch.events.count < ObservationLimits.batchCount { break }
    }
    #expect(received == (0...300).map(UInt64.init))
    #expect(buffer.read(after: cursor, epoch: epoch, now: 5).events.isEmpty)
  }

  @Test func longLivedConnectionSurvivesMoreThanOneDisplayWindow() {
    let buffer = ObservationBuffer()
    _ = buffer.read(after: 0, epoch: "", now: 1)
    let records = (0..<2048).map { _ in connection() }
    for record in records { #expect(buffer.record(record, now: 2)) }
    buffer.updateTraffic(records[0].id, receivedBytes: 4096, sentBytes: 2048, now: 3)
    let batch = buffer.read(
      after: 2048, epoch: buffer.read(after: 0, epoch: "", now: 3).epoch, now: 4)
    #expect(batch.events.first?.id == records[0].id)
    #expect(batch.events.first?.traffic?.receivedBytes == 4096)
    #expect(batch.captureDropped == 0)
  }

  @Test func captureBudgetIsIndependentAndOverloadIsExplicit() {
    let buffer = ObservationBuffer()
    _ = buffer.read(after: 0, epoch: "", now: 1)
    let first = connection()
    #expect(buffer.record(first, now: 2))
    for _ in 1..<ObservationLimits.captureCount { #expect(buffer.record(connection(), now: 2)) }
    #expect(!buffer.record(connection(), now: 2))
    buffer.close(first.id, receivedBytes: 100, sentBytes: 50, now: 3)
    #expect(buffer.record(connection(), now: 3))
    let batch = buffer.read(after: 0, epoch: "", now: 4)
    #expect(batch.captureDropped == 1)
  }

  @Test func closeCarriesFinalCountersAndPauseDoesNotRecordHiddenTraffic() {
    let buffer = ObservationBuffer()
    _ = buffer.read(after: 0, epoch: "", now: 1)
    let record = connection()
    buffer.record(record, now: 2)
    let opened = buffer.read(after: 0, epoch: "", now: 3)
    buffer.endLease()
    buffer.updateTraffic(record.id, receivedBytes: 9000, sentBytes: 6000, now: 4)
    let resumed = buffer.read(after: opened.cursor, epoch: opened.epoch, now: 5)
    #expect(resumed.events.isEmpty)
    buffer.close(record.id, receivedBytes: 10000, sentBytes: 7000, now: 6)
    let closed = buffer.read(after: resumed.cursor, epoch: resumed.epoch, now: 7)
    #expect(closed.events.first?.closedAt != nil)
    #expect(closed.events.first?.traffic?.receivedBytes == 10000)
  }

  @Test func worstMetadataAndCountersStillFitOriginalPayloadBudget() throws {
    let buffer = ObservationBuffer()
    _ = buffer.read(after: 0, epoch: "", now: 1)
    for _ in 0..<1024 {
      var flow = connection()
      flow.executablePath = String(repeating: "\\", count: 1024)
      flow.hostname = String(repeating: "\\", count: 255)
      flow.address = String(repeating: "\\", count: 128)
      buffer.record(flow, now: 2)
      buffer.close(flow.id, receivedBytes: .max, sentBytes: .max, now: 3)
    }
    let batch = buffer.read(after: 0, epoch: "", now: 4)
    #expect(batch.events.count == ObservationLimits.batchCount)
    let data = try JSONEncoder().encode(batch)
    #expect(data.count <= ObservationLimits.maximumPayloadBytes)
    #expect(try ObservationBatch.decode(data) == batch)
    var legacy = batch
    legacy.protocolVersion = 2
    legacy.trafficVersion = nil
    legacy.activeIDs = []
    #expect(try ObservationBatch.decode(JSONEncoder().encode(legacy)).protocolVersion == 2)
  }
}
