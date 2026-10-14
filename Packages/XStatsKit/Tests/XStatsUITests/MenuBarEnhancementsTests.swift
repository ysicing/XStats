// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Metrics
import Testing
@testable import XStatsUI

@MainActor
struct MenuBarEnhancementsTests {
    @Test func nativeMenuPreservesDurationOptionsAndHidesUnavailableFans() throws {
        let suite = "MenuBarEnhancementsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        model.settings.setModuleEnabled(.thermal, false)
        let menu = MenuBarController(model: model).contextMenu()
        let submenus = menu.items.compactMap(\.submenu)
        #expect(submenus.count == 1)
        #expect(submenus.first?.items.compactMap { $0.representedObject as? Int } == [15, 60, 120, 240, 300, 480, 720, 0])
        #expect(!model.keepAwake.isActive && model.fans.mode == .automatic)
    }


}
