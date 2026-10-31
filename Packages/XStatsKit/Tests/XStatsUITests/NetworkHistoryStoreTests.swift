// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SQLite3
import Testing
@testable import NetworkObservation
@testable import XStatsUI

struct NetworkHistoryStoreTests {
  @Test func mainlandAndTaiwanHongKongMacaoHaveIndependentHistoryGroups() async throws {
    let store = NetworkHistoryStore()
    let codes = ["CN", "TW", "HK", "MO"]
    let flows = codes.indices.map { record($0) }
    try await store.ingest(
      batch(
        flows.enumerated().map {
          event($0.element, sequence: Int64($0.offset + 1), seconds: 0, received: 0)
        }, epoch: "peer-regions"),
      session: UUID(), sessionStartedAt: start, observedAt: start)
    try await store.updateCountries(
      Dictionary(uniqueKeysWithValues: zip(flows.compactMap(\.address), codes)))
    let view = try await store.view(
      filter: .init(grouping: "country"), activeOnly: false, offset: 0, now: start)
    #expect(Set(view.groups.map(\.id)) == Set(codes))
    #expect(view.groups.allSatisfy { $0.count == 1 && !$0.hasChildren })
    for code in codes {
      let selected = try await store.view(
        filter: .init(grouping: "country", selection: code),
        activeOnly: false, offset: 0, now: start)
      #expect(
        selected.total == 1 && selected.records.first?.id == flows[codes.firstIndex(of: code)!].id)
    }
    await store.close()
  }

  @Test func schemaTwoAddsLocationMetadataWithoutLosingConnectionsOrTraffic() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = NetworkHistoryStore(url: url)
    let flow = record()
    let session = UUID()
    let now = start.addingTimeInterval(5)
    try await store.ingest(
      batch(
        [
          event(flow, sequence: 1, seconds: 0, received: 0),
          event(flow, sequence: 2, seconds: 5, received: 1000),
        ], epoch: "migration"),
      session: session, sessionStartedAt: start, observedAt: now)
    await store.close()
    var external: OpaquePointer?
    try #require(sqlite3_open(url.path, &external) == SQLITE_OK)
    let status = sqlite3_exec(
      external, "DROP TABLE geography; PRAGMA user_version=2", nil, nil, nil)
    sqlite3_close(external)
    try #require(status == SQLITE_OK)
    let reopened = NetworkHistoryStore(url: url)
    let view = try await reopened.view(
      filter: .init(), activeOnly: false, offset: 0, now: now)
    #expect(view.total == 1 && integral(view.points) == 1000)
    #expect(
      try await reopened.pendingLocationAddresses(version: IPRegionDatabase.version).count == 1)
    await reopened.close()
  }
  @Test func citySelectionAndTrafficUseCompleteHistoryWithOneLocationPerAddress() async throws {
    let store = NetworkHistoryStore()
    let session = UUID()
    var flows: [ObservedConnection] = []
    for index in 0..<700 {
      var flow = record(index)
      flow.address = index % 2 == 0 ? "223.5.5.5" : "114.114.114.114"
      flows.append(flow)
    }
    let opened = flows.enumerated().map {
      event($0.element, sequence: Int64($0.offset + 1), seconds: 0, received: 0)
    }
    try await store.ingest(
      batch(opened, epoch: "cities"), session: session, sessionStartedAt: start, observedAt: start)
    let closed = flows.enumerated().map {
      event($0.element, sequence: Int64($0.offset + 701), seconds: 5, received: 100, closed: true)
    }
    let now = start.addingTimeInterval(5)
    try await store.ingest(
      batch(closed, epoch: "cities"), session: session, sessionStartedAt: start, observedAt: now)
    try await store.updateCountries(["223.5.5.5": "CN", "114.114.114.114": "CN"])
    let locations = [
      "223.5.5.5": try #require(NetworkIPLocation.parse("中国|浙江省|杭州市|阿里|CN")),
      "114.114.114.114": try #require(NetworkIPLocation.parse("中国|江苏省|南京市|0|CN")),
    ]
    try await store.updateLocations(locations, version: IPRegionDatabase.version)
    #expect(try await store.pendingLocationAddresses(version: IPRegionDatabase.version).isEmpty)
    #expect(try await store.pendingLocationAddresses(version: "next").count == 2)
    let view = try await store.view(
      filter: .init(grouping: "country", selection: "CN|浙江|杭州"),
      activeOnly: false, offset: 200, now: now)
    #expect(view.total == 350 && view.records.count == 150)
    #expect(view.records.allSatisfy { $0.address == "223.5.5.5" })
    #expect(view.groups.count == 1 && view.groups.first?.id == "CN")
    #expect(view.groups.first?.count == 700 && view.groups.first?.hasChildren == true)
    #expect(view.regions.count == 1 && view.regions.first?.count == 350)
    let expanded = try await store.view(
      filter: .init(
        grouping: "country", selection: "CN", expandedRegions: ["CN", "CN|浙江", "CN|江苏"]),
      activeOnly: false, offset: 0, now: now)
    #expect(expanded.total == 700 && expanded.records.count == 200)
    #expect(expanded.groups.count == 5)
    #expect(expanded.groups.filter { $0.id != "CN" }.allSatisfy { $0.count == 350 })
    #expect(expanded.regions.count == 2 && expanded.regions.reduce(0) { $0 + $1.count } == 700)
    #expect(integral(expanded.points) == 70_000)
    let province = try await store.view(
      filter: .init(grouping: "country", selection: "CN|浙江"), activeOnly: false, offset: 0, now: now
    )
    #expect(province.total == 350 && integral(province.points) == 35_000)
    #expect(province.locations["223.5.5.5"] == locations["223.5.5.5"])
    #expect(view.locations.count == 1)
    #expect(integral(view.points) == 35_000)
    let expired = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(1000))
    #expect(expired.total == 0 && expired.locations.isEmpty)
    try await store.clear()
    // 迟到的详情不能重新插入已清空历史。
    try await store.updateLocations(locations, version: IPRegionDatabase.version)
    #expect(try await store.pendingLocationAddresses(version: "next").isEmpty)
  }
  @Test func localAndUnknownHistoryGroupsKeepTheirRecordsAndTrafficSeparate() async throws {
    let store = NetworkHistoryStore()
    var local = record()
    var unknown = record(1)
    local.address = "192.168.31.80"
    unknown.address = "8.8.8.8"
    try await store.ingest(
      batch(
        [
          event(local, sequence: 1, seconds: 0, received: 0),
          event(unknown, sequence: 2, seconds: 0, received: 0),
          event(local, sequence: 3, seconds: 5, received: 5000),
          event(unknown, sequence: 4, seconds: 5, received: 10_000),
        ], epoch: UUID().uuidString),
      session: UUID(), sessionStartedAt: start, observedAt: start.addingTimeInterval(5))
    for countries in [[:], ["192.168.31.80": "??", "8.8.8.8": "??"]] {
      try await store.updateCountries(countries)
      let view = try await store.view(
        filter: .init(grouping: "country"), activeOnly: false, offset: 0,
        now: start.addingTimeInterval(5))
      #expect(view.groups.count == 2)
      for (flow, expectedBytes) in [(local, 5000.0), (unknown, 10_000.0)] {
        let key = ConnectionGrouping.country.identifier(for: flow, countries: countries)
        let selected = try await store.view(
          filter: .init(grouping: "country", selection: key), activeOnly: false, offset: 0,
          now: start.addingTimeInterval(5))
        #expect(selected.records.map(\.id) == [flow.id])
        #expect(abs(integral(selected.points) - expectedBytes) < 0.01)
      }
    }
    await store.close()
  }

  @Test func historyCutoffAndIntervalStayIndependentOfLiveCapture() async throws {
    let store = NetworkHistoryStore()
    let session = UUID()
    let old = record()
    let recent = record(1, at: start.addingTimeInterval(400))
    let active = record(2)
    try await store.ingest(
      batch(
        [
          event(old, sequence: 1, seconds: 0, received: 0),
          event(active, sequence: 2, seconds: 0, received: 0),
          event(old, sequence: 3, seconds: 5, received: 100, closed: true),
          event(recent, sequence: 4, seconds: 400, received: 0),
          event(recent, sequence: 5, seconds: 410, received: 200, closed: true),
        ], epoch: "cutoff"), session: session, sessionStartedAt: start,
      observedAt: start.addingTimeInterval(410))
    let first = try await store.view(
      filter: .init(interval: 300, end: start.addingTimeInterval(300)),
      activeOnly: false, offset: 0, now: start.addingTimeInterval(410))
    #expect(Set(first.records.map(\.id)) == [old.id, active.id])
    #expect(first.points.count == 60 && integral(first.points) == 100)
    #expect(first.points.last?.date == start.addingTimeInterval(300))
    let next = try await store.view(
      filter: .init(interval: 300, end: start.addingTimeInterval(600)),
      activeOnly: false, offset: 0, now: start.addingTimeInterval(610))
    #expect(next.records.map(\.id) == [recent.id])
    #expect(integral(next.points) == 200)
    let live = try await store.view(
      filter: .init(interval: 60), activeOnly: true, offset: 0,
      now: start.addingTimeInterval(410))
    #expect(live.records.map(\.id) == [active.id])
    #expect(live.points.count == 12)
    let expired = try await store.view(
      filter: .init(interval: 300, end: start.addingTimeInterval(300)),
      activeOnly: false, offset: 0, now: start.addingTimeInterval(1300))
    #expect(expired.total == 0 && expired.points.allSatisfy { $0.receivedBytesPerSecond == nil })
    await store.close()
  }

  @Test func historicalClosureIsEvaluatedAtTheCutoff() async throws {
    let store = NetworkHistoryStore()
    let flow = record()
    try await store.ingest(
      batch(
        [
          event(flow, sequence: 1, seconds: 0, received: 0),
          event(flow, sequence: 2, seconds: 10, received: 100, closed: true),
        ], epoch: "closure"), session: UUID(), sessionStartedAt: start,
      observedAt: start.addingTimeInterval(10))
    let before = try await store.view(
      filter: .init(end: start.addingTimeInterval(5)),
      activeOnly: false, offset: 0, now: start.addingTimeInterval(10))
    #expect(before.records.count == 1 && before.records.first?.closedAt == nil)
    let after = try await store.view(
      filter: .init(end: start.addingTimeInterval(10)),
      activeOnly: false, offset: 0, now: start.addingTimeInterval(10))
    #expect(after.records.first?.closedAt == start.addingTimeInterval(10))
    await store.close()
  }

  @Test func retiringAnObservationSessionDoesNotClaimTheConnectionEnded() async throws {
    let store = NetworkHistoryStore()
    let flow = record()
    try await store.ingest(
      batch([event(flow, sequence: 1, seconds: 0, received: 0)], epoch: "retirement"),
      session: UUID(), sessionStartedAt: start, observedAt: start)
    let nextStart = start.addingTimeInterval(10)
    try await store.ingest(
      batch([], epoch: "retirement"), session: UUID(), sessionStartedAt: nextStart,
      observedAt: nextStart)
    let history = try await store.view(
      filter: .init(end: nextStart), activeOnly: false, offset: 0, now: nextStart)
    #expect(history.total == 1 && history.records.first?.closedAt == nil)
    let live = try await store.view(
      filter: .init(), activeOnly: true, offset: 0, now: nextStart)
    #expect(live.total == 0)
    await store.close()
  }

  // 对齐 5 秒边界：在 start+900 查询，窗口准确覆盖 [start,start+900)。
  private let start = Date(timeIntervalSince1970: 50_000)

  private func record(
    _ index: Int = 0, name: String = "Browser", at date: Date? = nil
  ) -> ObservedConnection {
    ObservedConnection(
      id: UUID(), timestamp: date ?? start, processID: Int32(100_000 + index),
      executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
      address: "203.0.113.\(index % 200 + 1)", hostname: "host-\(index).example.test",
      port: 443, transport: .tcp, direction: .outbound)
  }

  private func event(
    _ record: ObservedConnection, sequence: Int64, seconds: Double, received: UInt64,
    sent: UInt64? = nil, closed: Bool = false, observationID: UUID? = nil
  ) -> ObservedConnection {
    var value = record
    value.sequence = sequence
    let at = start.addingTimeInterval(seconds)
    value.traffic = .init(
      id: value.id, timestamp: at, receivedBytes: received, sentBytes: sent ?? received / 2)
    value.traffic?.observationID = observationID
    if closed { value.closedAt = at }
    return value
  }

  private func batch(
    _ events: [ObservedConnection], epoch: String, cursor: Int64? = nil,
    discarded: Int64 = 0, captureDropped: Int64 = 0
  ) -> ObservationBatch {
    var value = ObservationBatch(
      epoch: epoch, cursor: cursor ?? events.map(\.sequence).max() ?? 0,
      discarded: discarded, events: events)
    value.protocolVersion = 3
    value.trafficVersion = 2
    value.captureDropped = captureDropped
    return value
  }

  private func integral(_ points: [NetworkTrafficPoint], received: Bool = true) -> Double {
    points.reduce(0) {
      $0 + ((received ? $1.receivedBytesPerSecond : $1.sentBytesPerSecond) ?? 0) * 5
    }
  }

  private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
  }

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("network-history-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("network-history.sqlite")
  }

  /// 每批最多 64 条，游标按真实事件递增；没有额外的 Swift 元数据缓存参与存储查询。
  private func ingestRound(
    _ records: [ObservedConnection], round: Int, store: NetworkHistoryStore,
    epoch: String, session: UUID
  ) async throws {
    for offset in stride(from: 0, to: records.count, by: 64) {
      let upper = min(records.count, offset + 64)
      let events = (offset..<upper).map { index in
        event(
          records[index], sequence: Int64(round * records.count + index + 1),
          seconds: Double(round * 5), received: UInt64(round * 5000))
      }
      try await store.ingest(
        batch(events, epoch: epoch), session: session, sessionStartedAt: start,
        observedAt: start.addingTimeInterval(Double(round * 5)))
    }
  }

  @Test func fullFifteenMinutesRetainsFirstBucketAndEveryByteAcross1024Flows() async throws {
    let store = NetworkHistoryStore()
    let epoch = UUID().uuidString
    let session = UUID()
    let flows = (0..<1024).map { record($0, name: $0 % 2 == 0 ? "Browser" : "Editor") }
    for round in 0...180 {
      try await ingestRound(flows, round: round, store: store, epoch: epoch, session: session)
    }
    let now = start.addingTimeInterval(900)
    let first = try await store.view(filter: .init(), activeOnly: false, offset: 0, now: now)
    let second = try await store.view(filter: .init(), activeOnly: false, offset: 200, now: now)
    let last = try await store.view(filter: .init(), activeOnly: false, offset: 1000, now: now)
    #expect(first.total == 1024)
    #expect(first.records.count == 200)
    #expect(second.records.count == 200)
    #expect(last.records.count == 24)
    #expect(Set(first.records.map(\.id)).isDisjoint(with: second.records.map(\.id)))
    #expect(first.points.count == 180)
    #expect(first.points.first?.date == start.addingTimeInterval(5))
    #expect(first.points.first?.receivedBytesPerSecond == 1_024_000)
    #expect(first.points.allSatisfy { $0.receivedBytesPerSecond == 1_024_000 })
    #expect(integral(first.points) == Double(1024 * 900_000))
    #expect(integral(first.points, received: false) == Double(1024 * 450_000))
    #expect(integral(second.points) == integral(first.points))
    let editor = try await store.view(
      filter: .init(selection: "name:Editor"), activeOnly: true, offset: 400, now: now)
    #expect(editor.total == 512)
    #expect(editor.records.count == 112)
    #expect(editor.points.first?.receivedBytesPerSecond == 512_000)
    #expect(integral(editor.points) == Double(512 * 900_000))
    let diagnostics = try await store.diagnostics()
    #expect(diagnostics.connectionRows == 1024)
    #expect(diagnostics.trafficRows == 1024 * 180)
    #expect(diagnostics.trafficTotalRows == 180)
    #expect(diagnostics.databaseBytes <= NetworkHistoryStore.maximumDatabaseBytes)
    #expect(diagnostics.preparedStatementCount < 128)
    await store.close()
  }

  @Test func fileBacked1024FlowFifteenMinuteResourceProbe() async throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent(
        "xstats-network-history-probe-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NetworkHistoryStore(url: directory.appendingPathComponent("network-history.sqlite"))
    do {
      let clock = ContinuousClock()
      let epoch = UUID().uuidString
      let session = UUID()
      let flows = (0..<1024).map { record($0, name: $0 % 2 == 0 ? "Browser" : "Editor") }
      var batchCount = 0
      var batchTotalMilliseconds = 0.0
      var batchMaximumMilliseconds = 0.0
      let ingestStarted = clock.now
      for round in 0...180 {
        let observedAt = start.addingTimeInterval(Double(round * 5))
        for offset in stride(from: 0, to: flows.count, by: 64) {
          let upper = min(flows.count, offset + 64)
          let events = (offset..<upper).map { index in
            event(
              flows[index], sequence: Int64(round * flows.count + index + 1),
              seconds: Double(round * 5), received: UInt64(round * 5000))
          }
          let input = batch(events, epoch: epoch)
          let batchStarted = clock.now
          try await store.ingest(
            input, session: session, sessionStartedAt: start, observedAt: observedAt)
          let elapsed = milliseconds(batchStarted.duration(to: clock.now))
          batchTotalMilliseconds += elapsed
          batchMaximumMilliseconds = max(batchMaximumMilliseconds, elapsed)
          batchCount += 1
        }
      }
      // 总墙钟时间包含批次构造和计时开销；单批计时只包围 ingest，包括 actor 调度。
      let ingestWallMilliseconds = milliseconds(ingestStarted.duration(to: clock.now))
      let viewStarted = clock.now
      let result = try await store.view(
        filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(900))
      let viewMilliseconds = milliseconds(viewStarted.duration(to: clock.now))
      let applicationViewStarted = clock.now
      let application = try await store.view(
        filter: .init(selection: "name:Editor"), activeOnly: false, offset: 0,
        now: start.addingTimeInterval(900))
      let applicationViewMilliseconds = milliseconds(applicationViewStarted.duration(to: clock.now))
      // 诊断计数放在计时窗口外，不以全表 COUNT 污染写入和 view 耗时。
      let diagnostics = try await store.diagnostics()
      #expect(batchCount == 181 * 16)
      #expect(diagnostics.connectionRows == 1024)
      #expect(diagnostics.trafficRows == 1024 * 180)
      #expect(diagnostics.trafficTotalRows == 180)
      #expect(result.total == 1024)
      #expect(result.records.count == 200)
      #expect(result.points.count == 180)
      #expect(result.points.first?.date == start.addingTimeInterval(5))
      #expect(result.points.first?.receivedBytesPerSecond == 1_024_000)
      #expect(integral(result.points) == Double(1024 * 900_000))
      #expect(integral(result.points, received: false) == Double(1024 * 450_000))
      #expect(application.total == 512)
      #expect(integral(application.points) == Double(512 * 900_000))
      #expect(diagnostics.cacheBytes < 8 * 1024 * 1024)
      #expect(diagnostics.databaseFileBytes > 0)
      #expect(diagnostics.databaseBytes <= NetworkHistoryStore.maximumDatabaseBytes)
      #expect(diagnostics.walBytes <= NetworkHistoryStore.maximumWALBytes)
      #expect(diagnostics.storageBytes <= NetworkHistoryStore.maximumStorageBytes)
      #expect(diagnostics.discarded == 0)
      #expect(diagnostics.captureDropped == 0)
      let summary: [String: Any] = [
        "flows": flows.count,
        "rounds": 181,
        "events": flows.count * 181,
        "batches": batchCount,
        "ingestWallSeconds": ingestWallMilliseconds / 1000,
        "batchAverageMilliseconds": batchTotalMilliseconds / Double(batchCount),
        "batchMaximumMilliseconds": batchMaximumMilliseconds,
        "viewMilliseconds": viewMilliseconds,
        "applicationViewMilliseconds": applicationViewMilliseconds,
        "connectionRows": diagnostics.connectionRows,
        "trafficRows": diagnostics.trafficRows,
        "trafficTotalRows": diagnostics.trafficTotalRows,
        "databaseBytes": diagnostics.databaseBytes,
        "databaseFileBytes": diagnostics.databaseFileBytes,
        "walFileBytes": diagnostics.walBytes,
        "storageBytes": diagnostics.storageBytes,
        "cacheBytes": diagnostics.cacheBytes,
      ]
      let encoded = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
      // 测试仅输出一次聚合资源统计，不输出连接内容、地址、路径或设备信息。
      print("NetworkHistoryStoreResourceProbe \(String(decoding: encoded, as: UTF8.self))")
      await store.close()
    } catch {
      // 预算或写入失败仍向测试框架抛出；关闭句柄后由 defer 清理全部临时制品。
      await store.close()
      throw error
    }
  }

  @Test func newHighVolumeNeverEvictsUnexpiredHistoricalFlows() async throws {
    let store = NetworkHistoryStore()
    let epoch = UUID().uuidString
    let session = UUID()
    let flows = (0..<1024).map { record($0) }
    for round in 0...20 {
      try await ingestRound(flows, round: round, store: store, epoch: epoch, session: session)
    }
    let newcomers = (0..<2048).map { record($0 + 2000, name: "Flood") }
    for offset in stride(from: 0, to: newcomers.count, by: 64) {
      let events = (offset..<min(offset + 64, newcomers.count)).map { index in
        event(
          newcomers[index], sequence: Int64(21 * flows.count + index + 1),
          seconds: 895, received: 0)
      }
      try await store.ingest(
        batch(events, epoch: epoch), session: session, sessionStartedAt: start,
        observedAt: start.addingTimeInterval(895))
    }
    let view = try await store.view(
      filter: .init(selection: "name:Browser"), activeOnly: false, offset: 800,
      now: start.addingTimeInterval(895))
    #expect(view.total == 1024)
    #expect(view.records.count == 200)
    let earliest = try #require(view.points.first { $0.receivedBytesPerSecond != nil })
    #expect(earliest.date == start.addingTimeInterval(5))
    #expect(earliest.receivedBytesPerSecond == 1_024_000)
    #expect(integral(view.points) == Double(1024 * 100_000))
    let diagnostics = try await store.diagnostics()
    #expect(diagnostics.connectionRows == 3072)
    #expect(diagnostics.trafficRows == 20 * 1024)
    await store.close()
  }

  @Test func duplicateEventsAndSnapshotsAreIdempotentIncludingLegacyMetadataLookup() async throws {
    let store = NetworkHistoryStore()
    let flow = record()
    let epoch = UUID().uuidString
    let session = UUID()
    let opening = batch([event(flow, sequence: 1, seconds: 0, received: 0)], epoch: epoch)
    try await store.ingest(opening, session: session, sessionStartedAt: start, observedAt: start)
    let reporting = batch([event(flow, sequence: 2, seconds: 5, received: 5000)], epoch: epoch)
    for _ in 0..<3 {
      try await store.ingest(
        reporting, session: session, sessionStartedAt: start,
        observedAt: start.addingTimeInterval(5))
    }
    var legacy = batch([], epoch: epoch, cursor: 2)
    legacy.protocolVersion = 2
    legacy.trafficVersion = 1
    legacy.activeIDs = [flow.id]
    legacy.traffic = [try #require(event(flow, sequence: 2, seconds: 10, received: 10_000).traffic)]
    for _ in 0..<3 {
      try await store.ingest(
        legacy, session: session, sessionStartedAt: start, observedAt: start.addingTimeInterval(10))
    }
    let view = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(10))
    #expect(view.total == 1)
    #expect(integral(view.points) == 10_000)
    #expect(view.records.first?.traffic?.receivedBytes == 10_000)
    #expect(try await store.diagnostics().trafficRows == 2)
    await store.close()
  }

  @Test func inactiveSnapshotDoesNotDiscardBaselineBeforeNextBatchClose() async throws {
    let store = NetworkHistoryStore()
    let flow = record()
    let epoch = UUID().uuidString
    let session = UUID()
    var opening = batch([event(flow, sequence: 1, seconds: 0, received: 0)], epoch: epoch)
    opening.protocolVersion = 2
    opening.activeIDs = []
    try await store.ingest(opening, session: session, sessionStartedAt: start, observedAt: start)
    let closing = batch(
      [event(flow, sequence: 2, seconds: 5, received: 5000, closed: true)], epoch: epoch)
    try await store.ingest(
      closing, session: session, sessionStartedAt: start, observedAt: start.addingTimeInterval(5))
    let history = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(5))
    let active = try await store.view(
      filter: .init(), activeOnly: true, offset: 0, now: start.addingTimeInterval(5))
    #expect(history.total == 1)
    #expect(active.total == 0)
    #expect(active.groups.first?.count == 0)
    #expect(integral(history.points) == 5000)
    #expect(integral(active.points) == 5000)
    await store.close()
  }

  @Test func pauseOldOpenReplayAndSessionChangesDoNotCreateSpikes() async throws {
    let store = NetworkHistoryStore()
    let epoch = UUID().uuidString
    let oldSession = UUID()
    let newSession = UUID()
    let first = record()
    let unread = record(1, name: "Unread")
    try await store.ingest(
      batch(
        [
          event(first, sequence: 1, seconds: 0, received: 0),
          event(first, sequence: 2, seconds: 5, received: 5000),
        ], epoch: epoch),
      session: oldSession, sessionStartedAt: start, observedAt: start.addingTimeInterval(5))
    let resumedAt = start.addingTimeInterval(50)
    try await store.ingest(
      batch([event(unread, sequence: 3, seconds: 0, received: 0)], epoch: epoch),
      session: newSession, sessionStartedAt: resumedAt, observedAt: resumedAt)
    let unconfirmed = try await store.view(
      filter: .init(), activeOnly: true, offset: 0, now: resumedAt)
    #expect(unconfirmed.total == 0)
    try await store.ingest(
      batch(
        [
          event(first, sequence: 4, seconds: 60, received: 900_000),
          event(unread, sequence: 5, seconds: 60, received: 900_000),
          event(first, sequence: 6, seconds: 65, received: 905_000),
          event(unread, sequence: 7, seconds: 65, received: 905_000),
        ], epoch: epoch),
      session: newSession, sessionStartedAt: resumedAt,
      observedAt: start.addingTimeInterval(65))
    let view = try await store.view(
      filter: .init(), activeOnly: true, offset: 0, now: start.addingTimeInterval(65))
    #expect(view.total == 2)
    #expect(integral(view.points) == 15_000)
    #expect(view.points.contains { $0.receivedBytesPerSecond == nil })
    #expect(Set(view.points.filter { $0.receivedBytesPerSecond != nil }.map(\.segment)).count == 2)
    await store.close()
  }

  @Test func longGapRollbackAndUInt64MaxHaveSafeBaselines() async throws {
    let store = NetworkHistoryStore()
    let flow = record()
    let epoch = UUID().uuidString
    let session = UUID()
    let events = [
      event(flow, sequence: 1, seconds: 0, received: UInt64.max - 5000, sent: UInt64.max - 5000),
      event(flow, sequence: 2, seconds: 5, received: .max, sent: .max),
      event(flow, sequence: 3, seconds: 10, received: 1),
      event(flow, sequence: 4, seconds: 15, received: 5001),
      event(flow, sequence: 5, seconds: 50, received: 1_000_000),
      event(flow, sequence: 6, seconds: 55, received: 1_005_000),
    ]
    try await store.ingest(
      batch(events, epoch: epoch), session: session, sessionStartedAt: start,
      observedAt: start.addingTimeInterval(55))
    let view = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(55))
    #expect(integral(view.points) == 15_000)
    #expect(view.points.compactMap(\.receivedBytesPerSecond).allSatisfy { $0 <= 1000 })
    #expect(view.records.first?.traffic?.receivedBytes == 1_005_000)
    await store.close()
  }

  @Test func stableSourceLeasePreservesRetriedOldBatchAcrossClientSessions() async throws {
    let store = NetworkHistoryStore()
    let flow = record()
    let epoch = UUID().uuidString
    let source = UUID()
    let firstClient = UUID()
    try await store.ingest(
      batch(
        [event(flow, sequence: 1, seconds: 0, received: 0, observationID: source)], epoch: epoch),
      session: firstClient, sessionStartedAt: start, observedAt: start)
    let pending = event(flow, sequence: 2, seconds: 5, received: 5000, observationID: source)
    var invalid = event(record(1), sequence: 3, seconds: 5, received: 0, observationID: source)
    invalid.timestamp = Date(timeIntervalSince1970: .nan)
    await #expect(throws: NetworkHistoryStore.Failure.invalidData) {
      try await store.ingest(
        batch([pending, invalid], epoch: epoch), session: firstClient, sessionStartedAt: start,
        observedAt: start.addingTimeInterval(5))
    }
    let nextClient = UUID()
    let nextClientStartedAt = start.addingTimeInterval(8)
    let retried = batch([pending], epoch: epoch)
    for _ in 0..<2 {
      try await store.ingest(
        retried, session: nextClient, sessionStartedAt: nextClientStartedAt,
        observedAt: nextClientStartedAt)
    }
    let recovered = try await store.view(
      filter: .init(), activeOnly: true, offset: 0, now: nextClientStartedAt)
    #expect(recovered.total == 1)
    #expect(integral(recovered.points) == 5000)
    #expect(recovered.records.first?.traffic?.receivedBytes == 5000)
    try await store.ingest(
      batch(
        [event(flow, sequence: 3, seconds: 10, received: 10_000, observationID: source)],
        epoch: epoch),
      session: nextClient, sessionStartedAt: nextClientStartedAt,
      observedAt: start.addingTimeInterval(10))
    let continued = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(10))
    #expect(integral(continued.points) == 10_000)
    #expect(try await store.diagnostics().trafficRows == 2)
    await store.close()
  }

  @Test func newSourceLeaseStartsBaselineWithoutCountingHiddenTraffic() async throws {
    let store = NetworkHistoryStore()
    let flow = record()
    let epoch = UUID().uuidString
    let firstSource = UUID()
    let nextSource = UUID()
    try await store.ingest(
      batch(
        [
          event(flow, sequence: 1, seconds: 0, received: 0, observationID: firstSource),
          event(flow, sequence: 2, seconds: 5, received: 5000, observationID: firstSource),
        ], epoch: epoch),
      session: UUID(), sessionStartedAt: start, observedAt: start.addingTimeInterval(5))
    let nextClient = UUID()
    let nextClientStartedAt = start.addingTimeInterval(12)
    try await store.ingest(
      batch(
        [event(flow, sequence: 3, seconds: 10, received: 900_000, observationID: nextSource)],
        epoch: epoch),
      session: nextClient, sessionStartedAt: nextClientStartedAt, observedAt: nextClientStartedAt)
    let baseline = try await store.view(
      filter: .init(), activeOnly: true, offset: 0, now: nextClientStartedAt)
    #expect(baseline.total == 1)
    #expect(integral(baseline.points) == 5000)
    try await store.ingest(
      batch(
        [event(flow, sequence: 4, seconds: 15, received: 905_000, observationID: nextSource)],
        epoch: epoch),
      session: nextClient, sessionStartedAt: nextClientStartedAt,
      observedAt: start.addingTimeInterval(15))
    let continued = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(15))
    #expect(integral(continued.points) == 10_000)
    #expect(integral(continued.points, received: false) == 5000)
    #expect(continued.points.compactMap(\.receivedBytesPerSecond).allSatisfy { $0 <= 1000 })
    await store.close()
  }

  @Test func rapidPauseResumeSumsBothSegmentsInOneBucketAndKeepsLaterGap() async throws {
    let store = NetworkHistoryStore()
    let flow = record()
    let epoch = UUID().uuidString
    try await store.ingest(
      batch(
        [
          event(flow, sequence: 1, seconds: 0, received: 0),
          event(flow, sequence: 2, seconds: 2, received: 200),
        ], epoch: epoch),
      session: UUID(), sessionStartedAt: start, observedAt: start.addingTimeInterval(2))
    let resumedSession = UUID()
    let resumedAt = start.addingTimeInterval(2.5)
    try await store.ingest(
      batch(
        [
          event(flow, sequence: 3, seconds: 3, received: 900),
          event(flow, sequence: 4, seconds: 4, received: 1000),
        ], epoch: epoch),
      session: resumedSession, sessionStartedAt: resumedAt,
      observedAt: start.addingTimeInterval(4))
    let sameBucket = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(5))
    // 原段 200B 加恢复段 100B，不能因绘图采用新段标识而丢弃旧段字节。
    #expect(integral(sameBucket.points) == 300)
    #expect(integral(sameBucket.points, received: false) == 150)
    #expect(sameBucket.points.last?.receivedBytesPerSecond == 60)
    try await store.ingest(
      batch(
        [
          event(flow, sequence: 5, seconds: 20, received: 5000),
          event(flow, sequence: 6, seconds: 25, received: 5100),
        ], epoch: epoch),
      session: resumedSession, sessionStartedAt: resumedAt,
      observedAt: start.addingTimeInterval(25))
    let withGap = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(25))
    #expect(integral(withGap.points) == 400)
    let samples = withGap.points.filter { $0.receivedBytesPerSecond != nil }
    #expect(samples.count == 2)
    #expect(Set(samples.map(\.segment)).count == 2)
    #expect(withGap.points.suffix(4).prefix(3).allSatisfy { $0.receivedBytesPerSecond == nil })
    await store.close()
  }

  @Test func epochChangeRetainsHistoryAndStartsNewBaseline() async throws {
    let store = NetworkHistoryStore()
    let flow = record()
    let session = UUID()
    try await store.ingest(
      batch(
        [
          event(flow, sequence: 1, seconds: 0, received: 0),
          event(flow, sequence: 2, seconds: 5, received: 5000),
        ], epoch: UUID().uuidString),
      session: session, sessionStartedAt: start, observedAt: start.addingTimeInterval(5))
    try await store.ingest(
      batch(
        [
          event(flow, sequence: 1, seconds: 10, received: 500_000),
          event(flow, sequence: 2, seconds: 15, received: 505_000),
        ], epoch: UUID().uuidString),
      session: session, sessionStartedAt: start, observedAt: start.addingTimeInterval(15))
    let view = try await store.view(
      filter: .init(), activeOnly: true, offset: 0, now: start.addingTimeInterval(15))
    #expect(view.total == 1)
    #expect(integral(view.points) == 10_000)
    await store.close()
  }

  @Test func closedTTLUsesCloseTimeAndLongActiveConnectionsKeepMetadata() async throws {
    let store = NetworkHistoryStore()
    let flow = record()
    let epoch = UUID().uuidString
    let session = UUID()
    try await store.ingest(
      batch([event(flow, sequence: 1, seconds: 0, received: 0)], epoch: epoch),
      session: session, sessionStartedAt: start, observedAt: start)
    // 模拟存活超过 15 分钟的连接；长断档只建基线，不凭累计值伪造流量。
    try await store.ingest(
      batch([event(flow, sequence: 2, seconds: 1000, received: 1_000_000)], epoch: epoch),
      session: session, sessionStartedAt: start, observedAt: start.addingTimeInterval(1000))
    let active = try await store.view(
      filter: .init(), activeOnly: true, offset: 0, now: start.addingTimeInterval(1000))
    #expect(active.total == 1)
    try await store.ingest(
      batch(
        [event(flow, sequence: 3, seconds: 1005, received: 1_005_000, closed: true)], epoch: epoch),
      session: session, sessionStartedAt: start, observedAt: start.addingTimeInterval(1005))
    let retained = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(1905))
    #expect(retained.total == 1)
    _ = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(1920))
    #expect(try await store.diagnostics().connectionRows == 0)
    await store.close()
  }

  @Test func staleUnclosedConnectionsExpireWithoutAnyCloseEvent() async throws {
    let store = NetworkHistoryStore()
    let flow = record()
    let epoch = UUID().uuidString
    try await store.ingest(
      batch([event(flow, sequence: 1, seconds: 0, received: 0)], epoch: epoch),
      session: UUID(), sessionStartedAt: start, observedAt: start)
    let later = start.addingTimeInterval(901)
    let view = try await store.view(filter: .init(), activeOnly: true, offset: 0, now: later)
    #expect(view.total == 0)
    #expect(try await store.diagnostics().connectionRows == 0)
    await store.close()
  }

  @Test func reopenKeepsHistoryButCloseAndRestartBreakBaseline() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = NetworkHistoryStore(url: url)
    let flow = record()
    let epoch = UUID().uuidString
    let session = UUID()
    try await store.ingest(
      batch(
        [
          event(flow, sequence: 1, seconds: 0, received: 0),
          event(flow, sequence: 2, seconds: 5, received: 5000),
        ], epoch: epoch),
      session: session, sessionStartedAt: start, observedAt: start.addingTimeInterval(5))
    await store.close()
    // 即使传回原 session，close 产生的新 owner 也不能连接两次打开的基线。
    try await store.ingest(
      batch([event(flow, sequence: 3, seconds: 10, received: 900_000)], epoch: epoch),
      session: session, sessionStartedAt: start, observedAt: start.addingTimeInterval(10))
    await store.close()
    let reopened = NetworkHistoryStore(url: url)
    try await reopened.ingest(
      batch(
        [
          event(flow, sequence: 4, seconds: 15, received: 1_900_000),
          event(flow, sequence: 5, seconds: 20, received: 1_905_000),
        ], epoch: epoch),
      session: session, sessionStartedAt: start, observedAt: start.addingTimeInterval(20))
    let view = try await reopened.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(20))
    #expect(view.total == 1)
    #expect(integral(view.points) == 10_000)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let directory = try FileManager.default.attributesOfItem(
      atPath: url.deletingLastPathComponent().path)
    #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    await reopened.close()
  }

  @Test func groupingSearchCountryAndOffsetAreBoundedAndLiteral() async throws {
    let store = NetworkHistoryStore()
    let epoch = UUID().uuidString
    let session = UUID()
    let flows = (0..<600).map { record($0, name: String(format: "App%03d", $0)) }
    try await ingestRound(flows, round: 0, store: store, epoch: epoch, session: session)
    let view = try await store.view(filter: .init(), activeOnly: false, offset: -500, now: start)
    #expect(view.groups.count == 512)
    #expect(view.records.count == 200)
    let searched = try await store.view(
      filter: .init(search: "aPP599"), activeOnly: false, offset: 0, now: start)
    #expect(searched.total == 1)
    #expect(searched.groups.first?.id == "name:App599")
    let process = try await store.view(
      filter: .init(
        grouping: "process", selection: "\(flows[599].executablePath)#\(flows[599].processID)"),
      activeOnly: false, offset: 0, now: start)
    #expect(process.total == 1)
    let domain = try await store.view(
      filter: .init(grouping: "domain", selection: "host-599.example.test"), activeOnly: false,
      offset: 0, now: start)
    #expect(domain.total == 1)
    let addresses = try await store.pendingAddresses(limit: 10_000)
    #expect(addresses.count == 200)
    try await store.updateCountries(["203.0.113.200": "JP"])
    let country = try await store.view(
      filter: .init(grouping: "country", selection: "JP"), activeOnly: false, offset: 0, now: start)
    #expect(country.total == 3)
    #expect(country.countries["203.0.113.200"] == "JP")
    #expect(try await store.pendingAddresses(limit: -1).isEmpty)
    for query in ["' OR 1=1 --", "%", "_", "\\"] {
      let empty = try await store.view(
        filter: .init(search: query), activeOnly: false, offset: Int.max, now: start)
      #expect(empty.total == 0)
      #expect(empty.records.isEmpty)
    }
    let beyond = try await store.view(
      filter: .init(), activeOnly: false, offset: Int.max, now: start)
    #expect(beyond.total == 600)
    #expect(beyond.records.isEmpty)
    await store.close()
  }

  @Test func unicodeApplicationSearchIsCaseInsensitive() async throws {
    let store = NetworkHistoryStore()
    let flow = record(name: "Éclair")
    try await store.ingest(
      batch([event(flow, sequence: 1, seconds: 0, received: 0)], epoch: UUID().uuidString),
      session: UUID(), sessionStartedAt: start, observedAt: start)
    let view = try await store.view(
      filter: .init(search: "éCLAIR"), activeOnly: false, offset: 0, now: start)
    #expect(view.total == 1)
    await store.close()
  }

  @Test func sameNamedExecutablesMergeHistoryAndTrafficAcrossInstallations() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = NetworkHistoryStore(url: url)
    var first = record()
    var second = record(1)
    first.executablePath = "/opt/tools/codex"
    second.executablePath = "/Users/example/.vscode/bin/codex"
    try await store.ingest(
      batch(
        [
          event(first, sequence: 1, seconds: 0, received: 0),
          event(second, sequence: 2, seconds: 0, received: 0),
          event(first, sequence: 3, seconds: 5, received: 5000),
          event(second, sequence: 4, seconds: 5, received: 10_000),
        ], epoch: UUID().uuidString),
      session: UUID(), sessionStartedAt: start, observedAt: start.addingTimeInterval(5))
    let saved = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(5))
    #expect(saved.groups.count == 1)
    #expect(saved.groups.first?.count == 2)
    await store.close()
    // 模拟按完整路径分组的旧库，升级必须保留并合并原有连接和流量。
    var external: OpaquePointer?
    try #require(sqlite3_open(url.path, &external) == SQLITE_OK)
    let status = sqlite3_exec(
      external, "UPDATE connections SET app_key=path; PRAGMA user_version=3", nil, nil, nil)
    sqlite3_close(external)
    try #require(status == SQLITE_OK)

    let reopened = NetworkHistoryStore(url: url)
    let now = start.addingTimeInterval(5)
    let view = try await reopened.view(filter: .init(), activeOnly: false, offset: 0, now: now)
    #expect(view.groups.count == 1)
    let group = try #require(view.groups.first)
    #expect(group.name == "codex")
    #expect(group.count == 2)
    for search in ["", "codex"] {
      let selected = try await reopened.view(
        filter: .init(selection: group.id, search: search),
        activeOnly: false, offset: 0, now: now)
      #expect(Set(selected.records.map(\.id)) == [first.id, second.id])
      #expect(abs(integral(selected.points) - 15_000) < 0.01)
      #expect(abs(integral(selected.points, received: false) - 7500) < 0.01)
    }
    let processes = try await reopened.view(
      filter: .init(grouping: "process"), activeOnly: false, offset: 0, now: now)
    #expect(processes.groups.count == 2)
    let selectedProcess = try await reopened.view(
      filter: .init(grouping: "process", selection: "\(first.executablePath)#\(first.processID)"),
      activeOnly: false, offset: 0, now: now)
    #expect(selectedProcess.total == 1)
    #expect(abs(integral(selectedProcess.points) - 5000) < 0.01)
    await reopened.close()
  }

  @Test func versionedToolNamesResolveInPreviouslySavedHistory() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = NetworkHistoryStore(url: url)
    var flow = record()
    flow.executablePath = "/Users/example/.local/share/claude/versions/2.1.314"
    try await store.ingest(
      batch([event(flow, sequence: 1, seconds: 0, received: 0)], epoch: UUID().uuidString),
      session: UUID(), sessionStartedAt: start, observedAt: start)
    await store.close()
    var external: OpaquePointer?
    try #require(sqlite3_open(url.path, &external) == SQLITE_OK)
    let status = sqlite3_exec(
      external, "UPDATE connections SET name='2.1.314',app_key=path; PRAGMA user_version=3", nil,
      nil, nil)
    sqlite3_close(external)
    try #require(status == SQLITE_OK)

    let reopened = NetworkHistoryStore(url: url)
    for grouping in ["apps", "process"] {
      let view = try await reopened.view(
        filter: .init(grouping: grouping, search: "claude"),
        activeOnly: false, offset: 0, now: start)
      #expect(view.total == 1)
      #expect(view.groups.first?.name == "claude")
      #expect(view.records.first?.applicationName == "claude")
      #expect(view.groups.first?.applicationPath == nil)
    }
    await reopened.close()
  }

  @Test func unsearchedTrafficFastPathsMatchMetadataSearchFallback() async throws {
    let store = NetworkHistoryStore()
    let epoch = UUID().uuidString
    let session = UUID()
    let browser = record()
    let editor = record(1, name: "Editor")
    try await store.ingest(
      batch(
        [
          event(browser, sequence: 1, seconds: 0, received: 0),
          event(editor, sequence: 2, seconds: 0, received: 0),
          event(browser, sequence: 3, seconds: 5, received: 5000),
          event(editor, sequence: 4, seconds: 5, received: 10_000),
        ], epoch: epoch),
      session: session, sessionStartedAt: start, observedAt: start.addingTimeInterval(5))
    for filter in [
      NetworkHistoryFilter(),
      NetworkHistoryFilter(selection: "name:Editor"),
      NetworkHistoryFilter(
        grouping: "process", selection: "\(editor.executablePath)#\(editor.processID)"),
    ] {
      let fast = try await store.view(
        filter: filter, activeOnly: false, offset: 0, now: start.addingTimeInterval(5))
      var searched = filter
      searched.search = "example.test"
      let fallback = try await store.view(
        filter: searched, activeOnly: false, offset: 0, now: start.addingTimeInterval(5))
      #expect(fast.total == fallback.total)
      #expect(
        fast.points.map(\.receivedBytesPerSecond) == fallback.points.map(\.receivedBytesPerSecond))
      #expect(fast.points.map(\.sentBytesPerSecond) == fallback.points.map(\.sentBytesPerSecond))
      #expect(fast.points.map(\.segment) == fallback.points.map(\.segment))
    }
    await store.close()
  }

  @Test func discardedAndCaptureLossArePersistedWithoutRejectingUsefulEvents() async throws {
    let store = NetworkHistoryStore()
    let flow = record()
    let epoch = UUID().uuidString
    let session = UUID()
    let lossy = batch(
      [event(flow, sequence: 1, seconds: 0, received: 0)], epoch: epoch,
      discarded: 7, captureDropped: 9)
    for _ in 0..<2 {
      try await store.ingest(lossy, session: session, sessionStartedAt: start, observedAt: start)
    }
    let diagnostics = try await store.diagnostics()
    #expect(diagnostics.connectionRows == 1)
    #expect(diagnostics.discarded == 7)
    #expect(diagnostics.captureDropped == 9)
    await store.close()
  }

  @Test func identicalEmptyBatchesSkipWritesUntilHeartbeatWithoutHidingChanges() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = NetworkHistoryStore(url: url)
    let epoch = UUID().uuidString
    let session = UUID()
    let empty = batch([], epoch: epoch, cursor: 1)
    try await store.ingest(
      empty, session: session, sessionStartedAt: start, observedAt: start)
    var external: OpaquePointer?
    try #require(sqlite3_open(url.path, &external) == SQLITE_OK)
    defer { sqlite3_close(external) }
    // 精确检测 touched 的实际写入，不依赖文件时间戳、WAL 复用或耗时猜测。
    try #require(
      sqlite3_exec(
        external,
        """
        CREATE TRIGGER reject_idle_cursor_write BEFORE UPDATE ON cursors
        BEGIN SELECT RAISE(ABORT,'injected'); END
        """, nil, nil, nil) == SQLITE_OK)
    for seconds in stride(from: 2, through: 14, by: 2) {
      try await store.ingest(
        empty, session: session, sessionStartedAt: start,
        observedAt: start.addingTimeInterval(Double(seconds)))
    }
    // 新 session、推进游标与新的丢失计数都不能被空批快路径吞掉。
    await #expect(throws: NetworkHistoryStore.Failure.database(SQLITE_CONSTRAINT)) {
      try await store.ingest(
        empty, session: UUID(), sessionStartedAt: start.addingTimeInterval(14),
        observedAt: start.addingTimeInterval(14))
    }
    for changed in [
      batch([], epoch: epoch, cursor: 2),
      batch([], epoch: epoch, cursor: 1, discarded: 1),
      batch([], epoch: epoch, cursor: 1, captureDropped: 1),
    ] {
      await #expect(throws: NetworkHistoryStore.Failure.database(SQLITE_CONSTRAINT)) {
        try await store.ingest(
          changed, session: session, sessionStartedAt: start,
          observedAt: start.addingTimeInterval(14))
      }
    }
    await #expect(throws: NetworkHistoryStore.Failure.database(SQLITE_CONSTRAINT)) {
      try await store.ingest(
        empty, session: session, sessionStartedAt: start,
        observedAt: start.addingTimeInterval(15))
    }
    try #require(
      sqlite3_exec(external, "DROP TRIGGER reject_idle_cursor_write", nil, nil, nil) == SQLITE_OK)
    // 失败不会提前移动缓存水位；原心跳在移除写入故障后可重试。
    try await store.ingest(
      empty, session: session, sessionStartedAt: start,
      observedAt: start.addingTimeInterval(15))
    let diagnostics = try await store.diagnostics()
    #expect(diagnostics.cursorRows == 1)
    #expect(diagnostics.connectionRows == 0)
    #expect(diagnostics.discarded == 0)
    #expect(diagnostics.captureDropped == 0)
    await store.close()
  }

  @Test func invalidLaterEventRollsBackEntireBatchAndCursor() async throws {
    let store = NetworkHistoryStore()
    let epoch = UUID().uuidString
    let session = UUID()
    let valid = event(record(), sequence: 1, seconds: 0, received: 0)
    var invalid = event(record(1), sequence: 2, seconds: 5, received: 0)
    invalid.timestamp = Date(timeIntervalSince1970: .nan)
    await #expect(throws: NetworkHistoryStore.Failure.invalidData) {
      try await store.ingest(
        batch([valid, invalid], epoch: epoch), session: session, sessionStartedAt: start,
        observedAt: start)
    }
    let rolledBack = try await store.diagnostics()
    #expect(rolledBack.connectionRows == 0)
    #expect(rolledBack.cursorRows == 0)
    try await store.ingest(
      batch([valid], epoch: epoch), session: session, sessionStartedAt: start, observedAt: start)
    #expect(try await store.diagnostics().connectionRows == 1)
    await store.close()
  }

  @Test func sqliteWriteFailureRollsBackRowsAndAllowsSameCursorRetry() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = NetworkHistoryStore(url: url)
    _ = try await store.diagnostics()
    var external: OpaquePointer?
    try #require(sqlite3_open(url.path, &external) == SQLITE_OK)
    defer { sqlite3_close(external) }
    // 第二条 INSERT 在真正写入路径失败，第一条与 state/cursor 都必须回滚。
    try #require(
      sqlite3_exec(
        external,
        """
        CREATE TRIGGER injected_failure BEFORE INSERT ON connections
        WHEN NEW.pid=100001 BEGIN SELECT RAISE(ABORT,'injected'); END
        """, nil, nil, nil) == SQLITE_OK)
    let epoch = UUID().uuidString
    let session = UUID()
    let events = [
      event(record(), sequence: 1, seconds: 0, received: 0),
      event(record(1), sequence: 2, seconds: 0, received: 0),
    ]
    await #expect(throws: NetworkHistoryStore.Failure.database(SQLITE_CONSTRAINT)) {
      try await store.ingest(
        batch(events, epoch: epoch), session: session, sessionStartedAt: start, observedAt: start)
    }
    #expect(try await store.diagnostics().connectionRows == 0)
    #expect(try await store.diagnostics().cursorRows == 0)
    try #require(
      sqlite3_exec(external, "DROP TRIGGER injected_failure", nil, nil, nil) == SQLITE_OK)
    try await store.ingest(
      batch(events, epoch: epoch), session: session, sessionStartedAt: start, observedAt: start)
    #expect(try await store.diagnostics().connectionRows == 2)
    await store.close()
  }

  @Test func pinnedWALRejectsBudgetOverflowAndRetriesSameBatchAfterReaderEnds() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let walBudget = 256 * 1024
    let store = NetworkHistoryStore(url: url, walBudgetBytes: walBudget)
    let epoch = UUID().uuidString
    let session = UUID()
    try await store.ingest(
      batch([event(record(), sequence: 1, seconds: 0, received: 0)], epoch: epoch),
      session: session, sessionStartedAt: start, observedAt: start)
    var reader: OpaquePointer?
    try #require(sqlite3_open(url.path, &reader) == SQLITE_OK)
    defer { sqlite3_close(reader) }
    // 真正执行 SELECT 建立读快照，仅 BEGIN 不会钉住 WAL。
    try #require(
      sqlite3_exec(reader, "BEGIN; SELECT COUNT(*) FROM connections", nil, nil, nil) == SQLITE_OK)
    var committed = 1
    var rejected: ObservationBatch?
    for round in 0..<64 {
      let events = (0..<16).map { index in
        event(
          record(1 + round * 16 + index), sequence: Int64(2 + round * 16 + index),
          seconds: 5, received: 0)
      }
      let attempted = batch(events, epoch: epoch)
      do {
        try await store.ingest(
          attempted, session: session, sessionStartedAt: start,
          observedAt: start.addingTimeInterval(5))
        committed += events.count
      } catch let failure as NetworkHistoryStore.Failure {
        #expect(failure == .storageBudgetExceeded)
        rejected = attempted
        break
      }
    }
    let retry = try #require(rejected)
    let blocked = try await store.diagnostics()
    #expect(blocked.connectionRows == committed)
    #expect(blocked.trafficRows == 0)
    #expect(blocked.discarded == 0)
    #expect(blocked.captureDropped == 0)
    #expect(blocked.storageBytes == blocked.databaseFileBytes + blocked.walBytes)
    // 根据真实 WAL 文件头核对页大小和帧边界，不能把 journal_size_limit 当实际文件上限。
    let walURL = URL(fileURLWithPath: url.path + "-wal")
    let handle = try FileHandle(forReadingFrom: walURL)
    let header: Data
    do {
      header = try handle.read(upToCount: 32) ?? Data()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    try #require(header.count == 32)
    let magic = header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    #expect(magic == 0x377f_0682 || magic == 0x377f_0683)
    let pageSize = Int(header[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    #expect(pageSize == blocked.pageSize)
    #expect(blocked.walBytes >= 32)
    #expect((blocked.walBytes - 32) % (24 + pageSize) == 0)
    try #require(sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    try await store.ingest(
      retry, session: session, sessionStartedAt: start, observedAt: start.addingTimeInterval(5))
    let recovered = try await store.diagnostics()
    #expect(recovered.connectionRows == committed + retry.events.count)
    #expect(recovered.walBytes <= walBudget)
    #expect(recovered.databaseFileBytes <= NetworkHistoryStore.maximumDatabaseBytes)
    #expect(recovered.storageBytes <= NetworkHistoryStore.maximumDatabaseBytes + walBudget)
    #expect(NetworkHistoryStore.maximumStorageBytes == 320 * 1024 * 1024)
    await store.close()
  }

  @Test func pruningIsBoundedAndQueriesHideExpiredRowsBeforePhysicalCleanupFinishes() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = NetworkHistoryStore(url: url)
    let flow = record()
    let epoch = UUID().uuidString
    try await store.ingest(
      batch(
        [
          event(flow, sequence: 1, seconds: 0, received: 0),
          event(flow, sequence: 2, seconds: 5, received: 5000, closed: true),
        ], epoch: epoch),
      session: UUID(), sessionStartedAt: start, observedAt: start.addingTimeInterval(5))
    var external: OpaquePointer?
    try #require(sqlite3_open(url.path, &external) == SQLITE_OK)
    defer { sqlite3_close(external) }
    // 夹具通过 SQL 批量创建过期行，避免测试为陈旧数据执行数千次采集事务。
    let fixture = """
      WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<5000)
      INSERT INTO traffic(epoch,id,bucket,segment,rx,tx)
        SELECT '\(epoch)','\(flow.id.uuidString)',\(start.timeIntervalSince1970)-i*5,1,5,2 FROM n;
      WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<1100)
      INSERT INTO connections(epoch,id,sequence,opened_at,closed_at,pid,path,name,app_key,
        process_key,transport,direction,last_seen)
        SELECT c.epoch,printf('00000000-0000-4000-8000-%012d',i),1000+i,
          c.opened_at,c.opened_at,c.pid,c.path,c.name,c.app_key,c.process_key,
          c.transport,c.direction,c.last_seen
        FROM n CROSS JOIN connections c WHERE c.id='\(flow.id.uuidString)';
      """
    try #require(sqlite3_exec(external, fixture, nil, nil, nil) == SQLITE_OK)
    let before = try await store.diagnostics()
    #expect(before.trafficRows == 5001)
    #expect(before.connectionRows == 1101)
    let now = start.addingTimeInterval(30_000)
    let first = try await store.view(filter: .init(), activeOnly: false, offset: 0, now: now)
    #expect(first.total == 0)
    #expect(first.groups.isEmpty)
    #expect(first.points.count == 180)
    #expect(first.points.allSatisfy { $0.receivedBytesPerSecond == nil })
    let partial = try await store.diagnostics()
    #expect(partial.trafficRows == 5001 - 4096)
    #expect(partial.connectionRows == 1101 - 1024)
    _ = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: now)
    let finished = try await store.diagnostics()
    #expect(finished.trafficRows == 0)
    #expect(finished.connectionRows == 0)
    await store.close()
  }

  @Test func clearWatermarkRejectsLatePreclearBatchAcrossRestart() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = NetworkHistoryStore(url: url)
    let epoch = UUID().uuidString
    let session = UUID()
    // 整秒可精确往返 Unix/Reference 时间基准；不把亚微秒舍入当作元数据被改写。
    let beforeClear = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 10)
    var old = record(at: beforeClear)
    old.sequence = 1
    old.traffic = .init(id: old.id, timestamp: beforeClear, receivedBytes: 0, sentBytes: 0)
    try await store.ingest(
      batch([old], epoch: epoch), session: session, sessionStartedAt: beforeClear,
      observedAt: beforeClear)
    try await store.clear()
    await store.close()
    let reopened = NetworkHistoryStore(url: url)
    // 迟到事件的 sequence 甚至可以高于清空前已写入的 cursor。
    old.sequence = 2
    try await reopened.ingest(
      batch([old], epoch: epoch), session: session, sessionStartedAt: beforeClear,
      observedAt: Date())
    #expect(try await reopened.diagnostics().connectionRows == 0)
    #expect(try await reopened.diagnostics().trafficRows == 0)
    #expect(try await reopened.diagnostics().trafficTotalRows == 0)
    let later = Date(
      timeIntervalSince1970: ceil(Date().timeIntervalSince1970 / 5) * 5 + 5)
    // 原连接的 openedAt 早于清空时间，但新的周期报告代表继续观察，应当重新出现。
    var continued = old
    continued.sequence = 3
    continued.traffic = .init(
      id: old.id, timestamp: later, receivedBytes: 900_000, sentBytes: 450_000)
    try await reopened.ingest(
      batch([continued], epoch: epoch), session: session, sessionStartedAt: beforeClear,
      observedAt: later)
    let baseline = try await reopened.view(
      filter: .init(), activeOnly: true, offset: 0, now: later)
    #expect(baseline.records.first?.id == old.id)
    #expect(baseline.records.first?.timestamp == beforeClear)
    #expect(baseline.total == 1)
    #expect(integral(baseline.points) == 0)
    // 首次新报告只建立基线，后续仅累计清空后的差值，不恢复先前的 900,000 字节。
    continued.sequence = 4
    continued.traffic = .init(
      id: old.id, timestamp: later.addingTimeInterval(5),
      receivedBytes: 905_000, sentBytes: 452_500)
    try await reopened.ingest(
      batch([continued], epoch: epoch), session: session, sessionStartedAt: beforeClear,
      observedAt: later.addingTimeInterval(5))
    let resumed = try await reopened.view(
      filter: .init(), activeOnly: true, offset: 0, now: later.addingTimeInterval(5))
    #expect(resumed.total == 1)
    #expect(integral(resumed.points) == 5000)
    #expect(integral(resumed.points, received: false) == 2500)
    await reopened.close()
  }

  @Test func schemaOneBackfillsGlobalTotalsExactlyOnceAcrossReopen() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = NetworkHistoryStore(url: url)
    let flow = record()
    let epoch = UUID().uuidString
    let session = UUID()
    let events = [
      event(flow, sequence: 1, seconds: 0, received: 0),
      event(flow, sequence: 2, seconds: 5, received: 5000),
      event(flow, sequence: 3, seconds: 10, received: 10_000),
    ]
    try await store.ingest(
      batch(events, epoch: epoch), session: session, sessionStartedAt: start,
      observedAt: start.addingTimeInterval(10))
    await store.close()
    var external: OpaquePointer?
    try #require(sqlite3_open(url.path, &external) == SQLITE_OK)
    // 构造真实 v1 结构：保留原始连接、流量和游标，仅移除新表并恢复版本号。
    let status = sqlite3_exec(
      external, "DROP TABLE traffic_totals; PRAGMA user_version=1", nil, nil, nil)
    sqlite3_close(external)
    try #require(status == SQLITE_OK)
    for _ in 0..<2 {
      let reopened = NetworkHistoryStore(url: url)
      let view = try await reopened.view(
        filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(10))
      #expect(view.total == 1)
      #expect(integral(view.points) == 10_000)
      #expect(integral(view.points, received: false) == 5000)
      let diagnostics = try await reopened.diagnostics()
      #expect(diagnostics.trafficRows == 2)
      #expect(diagnostics.trafficTotalRows == 2)
      // 已提交批次回放不应再次累计原始桶或新汇总桶。
      try await reopened.ingest(
        batch(events, epoch: epoch), session: session, sessionStartedAt: start,
        observedAt: start.addingTimeInterval(10))
      let replayed = try await reopened.view(
        filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(10))
      #expect(integral(replayed.points) == 10_000)
      await reopened.close()
    }
  }

  @Test func totalsWriteFailureRollsBackOriginalTrafficAndBaselineBeforeRetry() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = NetworkHistoryStore(url: url)
    let flow = record()
    let epoch = UUID().uuidString
    let session = UUID()
    try await store.ingest(
      batch([event(flow, sequence: 1, seconds: 0, received: 0)], epoch: epoch),
      session: session, sessionStartedAt: start, observedAt: start)
    var external: OpaquePointer?
    try #require(sqlite3_open(url.path, &external) == SQLITE_OK)
    defer { sqlite3_close(external) }
    try #require(
      sqlite3_exec(
        external,
        """
        CREATE TRIGGER reject_totals BEFORE INSERT ON traffic_totals
        BEGIN SELECT RAISE(ABORT,'injected'); END
        """, nil, nil, nil) == SQLITE_OK)
    let reporting = batch(
      [event(flow, sequence: 2, seconds: 5, received: 5000)], epoch: epoch)
    await #expect(throws: NetworkHistoryStore.Failure.database(SQLITE_CONSTRAINT)) {
      try await store.ingest(
        reporting, session: session, sessionStartedAt: start,
        observedAt: start.addingTimeInterval(5))
    }
    let failed = try await store.diagnostics()
    #expect(failed.trafficRows == 0)
    #expect(failed.trafficTotalRows == 0)
    try #require(
      sqlite3_exec(external, "DROP TRIGGER reject_totals", nil, nil, nil) == SQLITE_OK)
    try await store.ingest(
      reporting, session: session, sessionStartedAt: start,
      observedAt: start.addingTimeInterval(5))
    let result = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(5))
    #expect(integral(result.points) == 5000)
    let filtered = try await store.view(
      filter: .init(selection: "name:Browser"), activeOnly: false, offset: 0,
      now: start.addingTimeInterval(5))
    #expect(integral(filtered.points) == integral(result.points))
    _ = try await store.view(
      filter: .init(), activeOnly: false, offset: 0, now: start.addingTimeInterval(920))
    let expired = try await store.diagnostics()
    #expect(expired.trafficRows == 0)
    #expect(expired.trafficTotalRows == 0)
    await store.close()
  }
}
