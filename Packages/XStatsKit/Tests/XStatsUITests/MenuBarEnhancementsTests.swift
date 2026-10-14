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
        let model = AppModel(settings: AppSettings(defaults: defaults), historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        model.settings.setModuleEnabled(.thermal, false)
        let menu = MenuBarController(model: model).contextMenu()
        let submenus = menu.items.compactMap(\.submenu)
        #expect(submenus.count == 1)
        #expect(submenus.first?.items.compactMap { $0.representedObject as? Int } == [15, 60, 120, 240, 300, 480, 720, 0])
        #expect(!model.keepAwake.isActive && model.fans.mode == .automatic)
    }

    @Test func spacingSurvivesImportPersistenceAndExport() throws {
        let suite = "MenuBarEnhancementsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for value in [4, 6, 8, 12] {
            let document = try JSONDecoder().decode(SettingsDocument.self, from: Data("{\"menuBarItemSpacing\":\(value)}".utf8))
            settings.apply(document)
            let restored = AppSettings(defaults: defaults)
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.exportDocument())) as? [String: Any])
            #expect(object["menuBarItemSpacing"] as? Int == value)
        }
    }

    @Test func spacingChangesCombinedImageWithoutChangingSingleItem() throws {
        let suite = "MenuBarEnhancementsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        func image(_ value: Int, items: [MenuBarItem]) throws -> NSImage {
            let document = try JSONDecoder().decode(SettingsDocument.self, from: Data("{\"menuBarItemSpacing\":\(value)}".utf8))
            settings.apply(document)
            settings.menuBarItems = Set(items)
            settings.menuBarLayout = .combined
            return MenuBarRenderer.image(for: model)
        }
        #expect(try image(12, items: [.cpu, .memory, .gpu]).size.width - image(4, items: [.cpu, .memory, .gpu]).size.width == 16)
        #expect(try image(12, items: [.cpu]).size == image(4, items: [.cpu]).size)
    }


}
