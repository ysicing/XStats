// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Metrics
import Testing
@testable import XStatsUI

@MainActor
struct MenuBarEnhancementsTests {
  @Test func invalidSpacingAndOldBackupsPreserveSupportedValues() throws {
    let suite = "MenuBarEnhancementsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.menuBarItemSpacing == 8)
    settings.menuBarItemSpacing = 6
    for json in ["{}", "{\"menuBarItemSpacing\":0}", "{\"menuBarItemSpacing\":999}"] {
      settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data(json.utf8)))
      #expect(settings.menuBarItemSpacing == 6)
    }
  }

  @Test func nativeMenuPreservesDurationOptionsAndHidesUnavailableFans() throws {
    let suite = "MenuBarEnhancementsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil,
      magpieClient: UnavailableMagpieClient())
    model.settings.setModuleEnabled(.thermal, false)
    let menu = MenuBarController(model: model).contextMenu()
    let submenus = menu.items.compactMap(\.submenu)
    #expect(submenus.count == 1)
    #expect(
      submenus.first?.items.compactMap { $0.representedObject as? Int } == [
        15, 60, 120, 240, 300, 480, 720, 0,
      ])
    #expect(!model.keepAwake.isActive && model.fans.mode == .automatic)
  }

  @Test func spacingSurvivesImportPersistenceAndExport() throws {
    let suite = "MenuBarEnhancementsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    for value in [4, 6, 8, 12] {
      let document = try JSONDecoder().decode(
        SettingsDocument.self, from: Data("{\"menuBarItemSpacing\":\(value)}".utf8))
      settings.apply(document)
      let restored = AppSettings(defaults: defaults)
      let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.exportDocument()))
          as? [String: Any])
      #expect(object["menuBarItemSpacing"] as? Int == value)
    }
  }

  @Test func spacingChangesCombinedImageWithoutChangingSingleItem() throws {
    let suite = "MenuBarEnhancementsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    func image(_ value: Int, items: [MenuBarItem]) throws -> NSImage {
      let document = try JSONDecoder().decode(
        SettingsDocument.self, from: Data("{\"menuBarItemSpacing\":\(value)}".utf8))
      settings.apply(document)
      settings.menuBarItems = Set(items)
      settings.menuBarLayout = .combined
      return MenuBarRenderer.image(for: model)
    }
    #expect(
      try image(12, items: [.cpu, .memory, .gpu]).size.width
        - image(4, items: [.cpu, .memory, .gpu]).size.width == 16)
    #expect(try image(12, items: [.cpu]).size == image(4, items: [.cpu]).size)
  }

  @Test func stableRanksRetainSurvivorsAndReplaceDeparturesWithFreshValues() {
    struct Entry: Identifiable, Equatable {
      let id: Int
      let value: Int
    }
    let ranked = [Entry(id: 2, value: 90), Entry(id: 4, value: 80), Entry(id: 1, value: 70)]
    let shown = StableOrder.arrange(ranked, previous: [1, 3, 2], limit: 3, id: \.id)
    #expect(shown.map(\.id) == [1, 4, 2])
    #expect(shown.map(\.value) == [70, 80, 90])
    #expect(StableOrder.arrange(ranked, previous: [], limit: 2, id: \.id).map(\.id) == [2, 4])
    #expect(StableOrder.arrange(ranked, previous: [1, 2, 4], limit: 0, id: \.id).isEmpty)
  }

  @Test func stableRanksBoundHistoryAcrossManyReplacements() {
    var previous: [Int] = []
    for start in 0..<1_000 {
      let ranked = Array(start..<(start + 100))
      previous = StableOrder.arrange(ranked, previous: previous, limit: 5, id: { $0 })
      #expect(previous.count == 5 && Set(previous).count == 5)
      #expect(Set(previous) == Set(ranked.prefix(5)))
    }
  }

  @Test func probeSummaryDistinguishesNoSamplesTimeoutAndLoss() {
    let empty = NetworkProbeSummary(samples: [])
    #expect(empty.count == 0 && empty.lossFraction == nil)
    let summary = NetworkProbeSummary(samples: [
      .init(latency: nil), .init(latency: 20), .init(latency: nil),
    ])
    #expect(summary.count == 3 && summary.latestLatency == nil)
    #expect(summary.lossFraction == 2.0 / 3)
    let recovered = NetworkProbeSummary(samples: [.init(latency: nil), .init(latency: 30)])
    #expect(recovered.latestLatency == 30 && recovered.lossFraction == 0.5)
  }

  @Test func diskReadWriteAveragesMatchRankingAndDecayTogether() {
    let store = MetricsStore(readBattery: false)
    var process = ProcessUsage(
      pid: 1, name: "Fixture", executablePath: nil,
      appBundlePath: "/Applications/Fixture.app", cpu: 0, memory: 0)
    process.diskRead = 4000
    process.diskWrite = 8000
    var snapshot = MetricsSnapshot()
    snapshot.processes = [process]
    store.apply(snapshot)
    let key = process.rowGroupID
    #expect(store.diskReadAverage.scores[key] == 1000)
    #expect(store.diskWriteAverage.scores[key] == 2000)
    process.diskRead = 0
    process.diskWrite = 0
    snapshot.processes = [process]
    store.apply(snapshot)
    #expect(store.diskReadAverage.scores[key] == 750)
    #expect(store.diskWriteAverage.scores[key] == 1500)
    #expect(store.diskRanking.scores[key] == 2250)
    snapshot.processes = []
    for _ in 0..<40 { store.apply(snapshot) }
    #expect(store.diskRanking.scores.isEmpty)
    #expect(store.diskReadAverage.scores.isEmpty && store.diskWriteAverage.scores.isEmpty)
  }
}
