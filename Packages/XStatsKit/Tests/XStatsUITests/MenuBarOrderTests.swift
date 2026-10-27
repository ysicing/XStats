// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// Adapted from gentpan/OpenStats ee0b5e4; see ThirdPartyNotices.md.

import Foundation
import Observation
import Testing
@testable import XStatsUI

@MainActor
struct MenuBarOrderTests {
  private struct Preferences {
    let name = "XStats.MenuBarOrderTests.\(UUID())"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func remove() { defaults.removePersistentDomain(forName: name) }
  }

  private func drawing(_ settings: AppSettings) -> [MenuBarItem] {
    AppModel(settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
      .drawnMenuBarItems
  }

  @Test func storedOrderDropsUnknownsAndCompletesMissingItems() {
    let fixture = Preferences()
    defer { fixture.remove() }
    fixture.defaults.set(["gpu", "unknown", "gpu", "cpu"], forKey: "menuBarOrder")
    let settings = AppSettings(defaults: fixture.defaults)
    #expect(
      settings.menuBarOrder == [
        .gpu, .cpu, .memory, .network, .disk, .temperature, .fan, .battery, .aiUsage, .display,
        .audio,
      ])
  }

  @Test func orderPersistsAndOnlyChangesCombinedIndicators() {
    let fixture = Preferences()
    defer { fixture.remove() }
    let settings = AppSettings(defaults: fixture.defaults)
    #expect(settings.menuBarOrder == MenuBarItem.allCases)
    settings.menuBarItems = [.cpu, .memory, .gpu]
    settings.menuBarLayout = .combined
    settings.setMenuBarOrder([.gpu, .memory, .cpu])
    #expect(drawing(settings) == [.gpu, .memory, .cpu])
    let reloaded = AppSettings(defaults: fixture.defaults)
    #expect(drawing(reloaded) == [.gpu, .memory, .cpu])
    reloaded.menuBarLayout = .separate
    #expect(drawing(reloaded) == [.cpu, .memory, .gpu])
    reloaded.trio = TrioConfiguration(outer: .cpu, center: .network, footer: .audio)
    reloaded.menuBarLayout = .iconOnly
    #expect(drawing(reloaded) == [.cpu, .network, .audio])
  }

  @Test func turningAnItemOffKeepsItsPlaceAndMovingDoesNotEnableModules() {
    let fixture = Preferences()
    defer { fixture.remove() }
    let settings = AppSettings(defaults: fixture.defaults)
    settings.menuBarLayout = .combined
    settings.menuBarItems = [.cpu, .memory, .network, .gpu]
    settings.setMenuBarOrder([.network, .gpu, .cpu, .memory])
    settings.setEnabled(.cpu, false)
    #expect(drawing(settings) == [.network, .gpu, .memory])
    settings.setEnabled(.cpu, true)
    #expect(drawing(settings) == [.network, .gpu, .cpu, .memory])
    settings.setModuleEnabled(.gpu, false)
    settings.moveMenuBarItem(.gpu, by: -1)
    #expect(!settings.isModuleEnabled(for: .gpu))
    #expect(!settings.orderedMenuBarItems.contains(.gpu))
  }

  @Test func movesStopAtEdgesAndRejectLargeOffsets() {
    let fixture = Preferences()
    defer { fixture.remove() }
    let settings = AppSettings(defaults: fixture.defaults)
    settings.moveMenuBarItem(.cpu, by: -1)
    settings.moveMenuBarItem(.audio, by: 1)
    settings.moveMenuBarItem(.cpu, by: 2)
    #expect(settings.menuBarOrder == MenuBarItem.allCases)
    settings.moveMenuBarItem(.memory, by: -1)
    #expect(Array(settings.menuBarOrder.prefix(3)) == [.memory, .cpu, .network])
    settings.setMenuBarOrder(MenuBarItem.allCases)
    settings.moveMenuBarItem(.battery, by: -1, among: MenuBarItem.allCases.filter { $0 != .fan })
    #expect(Array(settings.menuBarOrder[5...7]) == [.battery, .fan, .temperature])
  }

  @Test func orderSyncsAndOldDocumentsPreserveCurrentOrder() throws {
    let source = Preferences()
    let destination = Preferences()
    defer {
      source.remove()
      destination.remove()
    }
    let settings = AppSettings(defaults: source.defaults)
    settings.menuBarLayout = .combined
    settings.setMenuBarOrder([.network, .gpu, .memory, .cpu])
    let document = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    let target = AppSettings(defaults: destination.defaults)
    target.apply(document)
    #expect(target.menuBarOrder == settings.menuBarOrder)
    #expect(drawing(target) == drawing(settings))
    let old = try JSONDecoder().decode(
      SettingsDocument.self, from: Data(#"{"schema":1,"menuBarItems":["cpu"]}"#.utf8))
    target.apply(old)
    #expect(target.menuBarOrder == settings.menuBarOrder)
    var future = SettingsDocument()
    future.menuBarOrder = ["fan", "future", "fan", "cpu"]
    target.apply(future)
    #expect(Array(target.menuBarOrder.prefix(4)) == [.fan, .cpu, .memory, .network])
  }

  @Test func movingInvalidatesObservedDrawingOrder() async {
    let fixture = Preferences()
    defer { fixture.remove() }
    let settings = AppSettings(defaults: fixture.defaults)
    settings.menuBarLayout = .combined
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    await confirmation("drawing order changes", expectedCount: 1) { confirmed in
      withObservationTracking {
        _ = model.drawnMenuBarItems
      } onChange: {
        confirmed()
      }
      settings.moveMenuBarItem(.memory, by: -1)
    }
  }
}
