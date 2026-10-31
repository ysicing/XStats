// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NetworkObservation
import SwiftUI
import Testing
@testable import XStatsUI

struct NetworkConnectionsPresentationTests {
  @Test func mapIncludesTaiwanInChinaHighlightWithoutChangingConnectionRegions() async throws {
    let world = await OfflineGeography().world()
    let mainland = try #require(world.first { $0.code == "CN" })
    let taiwan = try #require(world.first { $0.code == "TW" })
    #expect(!mainland.rings.isEmpty && !taiwan.rings.isEmpty)
    #expect(taiwan.longitude > 119 && taiwan.longitude < 123)
    #expect(taiwan.latitude > 21 && taiwan.latitude < 26)

    let flows = (0..<2).map { record($0, at: Double($0)) }
    let countries = [flows[0].address!: "CN", flows[1].address!: "TW"]
    for code in ["CN", "TW"] {
      let filter = NetworkConnectionFilter(
        grouping: .country, selection: code, query: "", countries: countries)
      let filtered = flows.filter(filter.matches)
      #expect(filtered.count == 1)
      let nodes = NetworkMapDestination.make(
        world: world, records: filtered, countries: countries)
      #expect(nodes.map(\.id) == [code])
      let highlighted = Set(nodes.map(\.country.mapRegionCode))
      #expect(
        Set(world.filter { highlighted.contains($0.mapRegionCode) }.map(\.code)) == ["CN", "TW"])
    }
  }

  @Test func mapSeparatesMainlandCitiesAndKeepsOtherCountriesGrouped() throws {
    let world = [
      NetworkCountry(code: "CN", longitude: 105, latitude: 35, rings: []),
      NetworkCountry(code: "US", longitude: -100, latitude: 40, rings: []),
    ]
    let flows = (0..<4).map { record($0, at: Double($0)) }
    let locations = [
      flows[0].address!: try #require(NetworkIPLocation.parse("中国|浙江省|杭州市|阿里|CN")),
      flows[1].address!: try #require(NetworkIPLocation.parse("中国|浙江省|杭州市|电信|CN")),
      flows[2].address!: try #require(NetworkIPLocation.parse("中国|江苏省|南京市|0|CN")),
    ]
    let countries = Dictionary(
      uniqueKeysWithValues: flows.enumerated().map {
        ($0.element.address!, $0.offset == 3 ? "US" : "CN")
      })
    let nodes = NetworkMapDestination.make(
      world: world, records: flows, countries: countries, locations: locations)
    #expect(nodes.count == 3)
    #expect(nodes.first(where: { $0.id == "CN|浙江|杭州" })?.count == 2)
    #expect(nodes.first(where: { $0.id == "CN|江苏|南京" })?.count == 1)
    #expect(nodes.first(where: { $0.id == "US" })?.count == 1)
    let places = countries.merging(locations.compactMapValues(\.mapKey)) { _, new in new }
    let filter = NetworkConnectionFilter(
      grouping: .country, selection: "CN|浙江|杭州", query: "", countries: places)
    #expect(flows.filter(filter.matches).count == 2)
  }
  @Test func mapZoomKeepsTheGestureAnchorStationary() {
    let size = CGSize(width: 800, height: 416)
    let viewport = NetworkMapViewport().zoomed(
      by: 2, anchor: UnitPoint(x: 0.75, y: 0.25), in: size)
    #expect(viewport.scale == 2)
    #expect(viewport.offset == CGSize(width: -200, height: 104))
    let restored = viewport.zoomed(by: 0.5, anchor: UnitPoint(x: 0.75, y: 0.25), in: size)
    #expect(restored == NetworkMapViewport())
  }

  @Test func mapPanAndResizeKeepTheWorldWithinReach() {
    let size = CGSize(width: 800, height: 416)
    let viewport = NetworkMapViewport().zoomed(by: 2, in: size)
      .panned(by: CGSize(width: 10_000, height: -10_000), in: size)
    #expect(viewport.offset == CGSize(width: 384, height: -184))
    let narrow = viewport.bounded(in: CGSize(width: 400, height: 416))
    #expect(narrow.offset == CGSize(width: 184, height: 0))
    #expect(viewport.zoomed(by: 0.01, in: size) == NetworkMapViewport())
    #expect(
      NetworkMapViewport().panned(by: CGSize(width: 200, height: 200), in: size).offset == .zero)
  }

  @Test func mapZoomRejectsInvalidValuesAndCapsResourceUse() {
    let size = CGSize(width: 800, height: 416)
    #expect(NetworkMapViewport().zoomed(by: 100, in: size).scale == 6)
    #expect(NetworkMapViewport().zoomed(by: .nan, in: size) == NetworkMapViewport())
    #expect(NetworkMapViewport().zoomed(by: -.infinity, in: size) == NetworkMapViewport())
    #expect(
      NetworkMapViewport(
        scale: .infinity, offset: CGSize(width: CGFloat.nan, height: CGFloat.infinity)
      )
      .bounded(in: size) == NetworkMapViewport())
  }

  @Test func persistedUpdatesDoNotRefreshAPausedOrInvisiblePage() {
    let previous = historyQuery()
    let updated = historyQuery(revision: 2)
    #expect(!updated.shouldQuery(after: previous, isReading: false))
    #expect(updated.shouldQuery(after: previous, isReading: true))
    #expect(updated.hasSamePage(as: previous))
    #expect(!historyQuery(visible: false).shouldQuery(after: nil, isReading: true))
    #expect(!historyQuery(enabled: false).shouldQuery(after: nil, isReading: true))
  }

  @Test func pausedHistoryStillAllowsExplicitQueriesAndInitialLoad() {
    let previous = historyQuery()
    let queries = [
      historyQuery(selection: "another-app"),
      historyQuery(search: "example"),
      historyQuery(activeOnly: false),
      historyQuery(offset: 200),
      historyQuery(refresh: 1),
    ]
    #expect(previous.shouldQuery(after: nil, isReading: false))
    for query in queries {
      #expect(query.shouldQuery(after: previous, isReading: false))
    }
    #expect(!queries[0].hasSamePage(as: previous))
    #expect(!queries[3].hasSamePage(as: previous))
    #expect(queries[4].hasSamePage(as: previous))
  }

  @Test func paginationUsesDatabaseTotalBeyondTheRealtimeWindow() {
    let page = NetworkHistoryPagination(offset: 600, count: 200, total: 2500)
    #expect(page.first == 601 && page.last == 800)
    #expect(page.hasPrevious && page.hasNext)
    #expect(page.previousOffset == 400 && page.nextOffset == 800)
    let last = NetworkHistoryPagination(offset: 2400, count: 100, total: 2500)
    #expect(last.first == 2401 && last.last == 2500)
    #expect(last.hasPrevious && !last.hasNext)
    let empty = NetworkHistoryPagination(offset: 0, count: 0, total: 0)
    #expect(empty.first == 0 && empty.last == 0)
    #expect(!empty.hasPrevious && !empty.hasNext)
  }

  @Test func expiredHistoryClampsToAValidPage() {
    #expect(NetworkHistoryPagination.validOffset(600, total: 401) == 400)
    #expect(NetworkHistoryPagination.validOffset(600, total: 400) == 200)
    #expect(NetworkHistoryPagination.validOffset(600, total: 0) == 0)
    #expect(NetworkHistoryPagination.validOffset(-200, total: 2500) == 0)
  }

  @Test func databaseGroupCountsDoNotDependOnPageRecords() {
    let group = NetworkConnectionGroup(
      id: "example", name: "Example", applicationPath: nil, records: [], processID: 123,
      historyCount: 2500)
    #expect(group.count == 2500)
    #expect(group.records.isEmpty)
    #expect(group.processID == 123)
  }

  @Test func databaseChartWindowsKeepMissingBucketsAndSegments() {
    let points: [NetworkTrafficPoint] = (1...180).map { index -> NetworkTrafficPoint in
      let received: Double? = index == 175 ? nil : Double(index)
      return NetworkTrafficPoint(
        date: Date(timeIntervalSince1970: Double(index * 5)),
        receivedBytesPerSecond: received,
        sentBytesPerSecond: 0, segment: index < 177 ? 0 : 1)
    }
    let minute = NetworkTrafficChartSample.window(points, interval: 60)
    #expect(minute.count == 12)
    #expect(minute.first?.date == points[168].date && minute.last?.date == points.last?.date)
    #expect(minute[6].receivedBytesPerSecond == nil)
    #expect(minute.first?.segment == 0 && minute.last?.segment == 1)
    #expect(NetworkTrafficChartSample.window(points, interval: 300).count == 60)
    #expect(NetworkTrafficChartSample.window(points, interval: 900).count == 180)
    #expect(NetworkTrafficChartSample.window([], interval: 300).isEmpty)
  }

  @Test func processIdentitySurvivesAnEmptyActiveGroup() {
    let flow = record(0, at: 100)
    let group = NetworkConnectionGroup(
      id: "process", name: flow.applicationName, applicationPath: flow.applicationPath,
      records: [flow], processID: flow.processID)
    let empty = group.filteringActiveConnections([], onlyActive: true)
    #expect(empty.records.isEmpty)
    #expect(empty.id == group.id)
    #expect(empty.processID == flow.processID)
  }
  @Test func chartBreaksEachDirectionAtMissingSamplesAndCoreSegments() {
    let points = [
      NetworkTrafficPoint(
        date: Date(timeIntervalSince1970: 5), receivedBytesPerSecond: 10,
        sentBytesPerSecond: 20, segment: 0),
      NetworkTrafficPoint(
        date: Date(timeIntervalSince1970: 10), receivedBytesPerSecond: nil,
        sentBytesPerSecond: 20, segment: 0),
      NetworkTrafficPoint(
        date: Date(timeIntervalSince1970: 15), receivedBytesPerSecond: 0,
        sentBytesPerSecond: 20, segment: 0),
      NetworkTrafficPoint(
        date: Date(timeIntervalSince1970: 20), receivedBytesPerSecond: 10,
        sentBytesPerSecond: 20, segment: 1),
    ]
    let samples = NetworkTrafficChartSample.make(points: points)
    let received = samples.filter { $0.direction == .received }
    let sent = samples.filter { $0.direction == .sent }
    #expect(received.count == 3)
    #expect(sent.count == 4)
    #expect(received[0].series != received[1].series)
    #expect(received[1].series != received[2].series)
    #expect(sent[0].series == sent[2].series)
    #expect(sent[2].series != sent[3].series)
    #expect(received[1].rate == 0)
    #expect(Set(samples.map(\.id)).count == samples.count)
  }

  @Test func missingAndInvalidRatesDoNotBecomeZeroes() {
    let samples = NetworkTrafficChartSample.make(points: [
      NetworkTrafficPoint(
        date: Date(timeIntervalSince1970: 5), receivedBytesPerSecond: nil,
        sentBytesPerSecond: nil, segment: 0),
      NetworkTrafficPoint(
        date: Date(timeIntervalSince1970: 10), receivedBytesPerSecond: .infinity,
        sentBytesPerSecond: -1, segment: 0),
    ])
    #expect(samples.isEmpty)
  }

  @Test func mapMergesCountriesAndKeepsOnlyTwelveRecentDestinations() {
    let world = (0..<13).map {
      NetworkCountry(code: "C\($0)", longitude: 0, latitude: 0, rings: [])
    }
    var records = (0..<13).map { record($0, at: Double(100 + $0)) }
    var countries = Dictionary(
      uniqueKeysWithValues: (0..<13).map {
        ("203.0.113.\($0)", "C\($0)")
      })
    records.append(record(20, at: 120))
    countries["203.0.113.20"] = "C12"
    let destinations = NetworkMapDestination.make(
      world: world, records: records, countries: countries)
    #expect(destinations.count == 12)
    #expect(destinations.first?.id == "C12")
    #expect(destinations.first?.count == 2)
    #expect(!destinations.contains { $0.id == "C0" })
  }

  @Test func flightsWaitForCountryLookupAndNeverReplayExistingOrPausedFlows() {
    let existing = record(0, at: 99)
    let backlog = record(1, at: 98)
    let incoming = record(2, at: 101)
    let countries = ["203.0.113.0": "US", "203.0.113.1": "US", "203.0.113.2": "JP"]
    var activity = NetworkMapActivity()
    activity.begin(records: [existing], at: Date(timeIntervalSince1970: 100))
    #expect(activity.consume(records: [existing, backlog], countries: countries).isEmpty)
    #expect(activity.consume(records: [existing, backlog, incoming], countries: [:]).isEmpty)
    #expect(
      activity.consume(records: [existing, backlog, incoming], countries: countries) == ["JP"])
    #expect(activity.consume(records: [existing, backlog, incoming], countries: countries).isEmpty)
    activity.begin(records: [existing], at: nil)
    #expect(activity.consume(records: [incoming], countries: countries).isEmpty)
    activity.begin(records: [], at: Date(timeIntervalSince1970: 200))
    #expect(activity.consume(records: [incoming], countries: countries).isEmpty)
  }

  @Test func multipleNewFlowsToOneCountryProduceOneFlight() {
    var activity = NetworkMapActivity()
    activity.begin(records: [], at: Date(timeIntervalSince1970: 100))
    let records = [record(0, at: 101), record(1, at: 102)]
    let countries = ["203.0.113.0": "US", "203.0.113.1": "US"]
    #expect(activity.consume(records: records, countries: countries) == ["US"])
    #expect(activity.consume(records: records, countries: countries).isEmpty)
  }

  @Test(arguments: ConnectionGrouping.allCases)
  func historicalFiltersMatchSavedMetadataAfterConnectionEnds(_ grouping: ConnectionGrouping) {
    var ended = record(0, at: 100)
    ended.closedAt = Date(timeIntervalSince1970: 120)
    let countries = ["203.0.113.0": "US"]
    let selection = grouping.identifier(for: ended, countries: countries)
    let filter = NetworkConnectionFilter(
      grouping: grouping, selection: selection, query: "EXAMPLE", countries: countries)
    #expect(filter.matches(ended))
    let other = NetworkConnectionFilter(
      grouping: grouping, selection: "different", query: "", countries: countries)
    #expect(!other.matches(ended))
    let unmatchedSearch = NetworkConnectionFilter(
      grouping: grouping, selection: nil, query: "unmatched", countries: countries)
    #expect(!unmatchedSearch.matches(ended))
  }

  @Test func applicationFilterIncludesSiblingProcessesButProcessFilterDoesNot() {
    let first = record(0, at: 100)
    let second = record(1, at: 101)
    let application = NetworkConnectionFilter(
      grouping: .apps, selection: first.applicationPath, query: "", countries: [:])
    let process = NetworkConnectionFilter(
      grouping: .process,
      selection: ConnectionGrouping.process.identifier(for: first, countries: [:]),
      query: "", countries: [:])
    #expect(application.matches(first) && application.matches(second))
    #expect(process.matches(first) && !process.matches(second))
  }

  private func record(_ index: Int, at timestamp: TimeInterval) -> ObservedConnection {
    ObservedConnection(
      id: UUID(), timestamp: Date(timeIntervalSince1970: timestamp),
      processID: Int32(index + 100),
      executablePath: "/Applications/Example.app/Contents/MacOS/Example",
      address: "203.0.113.\(index)", hostname: "example.com", port: 443,
      transport: .tcp, direction: .outbound)
  }

  private func historyQuery(
    selection: String? = nil, search: String = "", activeOnly: Bool = true,
    offset: Int = 0, revision: Int = 1, visible: Bool = true, enabled: Bool = true, refresh: Int = 0
  ) -> NetworkHistoryQueryKey {
    NetworkHistoryQueryKey(
      filter: NetworkHistoryFilter(grouping: "apps", selection: selection, search: search),
      activeOnly: activeOnly, offset: offset, historyRevision: revision,
      visibility: visible, enabled: enabled, refresh: refresh)
  }
}
