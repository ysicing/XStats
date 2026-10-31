// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import XStatsUI

struct CommandBarTests {
  @MainActor @Test func experimentalFeatureDefaultsOnAndPersistsItsChoice() throws {
    let suite = "XStats.CommandBarTests.feature.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.commandBarEnabled)
    #expect(HotKeyAction.openCommandBar.isEnabled(in: settings))
    settings.commandBarEnabled = false
    #expect(!AppSettings(defaults: defaults).commandBarEnabled)
    #expect(!HotKeyAction.openCommandBar.isEnabled(in: settings))
    #expect(HotKeyAction.toggleMainWindow.isEnabled(in: settings))
    settings.commandBarEnabled = true
    #expect(AppSettings(defaults: defaults).commandBarEnabled)
  }

  @MainActor @Test func backupRestoresDisabledFeatureAndMissingFieldPreservesChoice() throws {
    let suite = "XStats.CommandBarTests.backup.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let oldDocument = try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8))
    settings.apply(oldDocument)
    #expect(settings.commandBarEnabled)
    settings.commandBarEnabled = false
    let saved = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    settings.commandBarEnabled = true
    settings.apply(saved)
    #expect(!settings.commandBarEnabled)
    settings.apply(oldDocument)
    #expect(!settings.commandBarEnabled)
  }

  @MainActor @Test func catalogUsesExistingRoutesAndStableIdentifiers() {
    let commands = AppCommand.catalog(supportsFans: false)
    #expect(Set(commands.map(\.id)).count == commands.count)
    #expect(!commands.contains { $0.action == .route(.open(.thermal)) })
    #expect(!commands.contains { $0.action == .route(.open(.settingsAccount)) })
    #expect(commands.contains { $0.action == .route(.open(.connections)) })
    #expect(commands.contains { $0.action == .route(.speedTest) })
    #expect(commands.contains { $0.action == .route(.egress) })
    #expect(commands.contains { $0.action == .route(.rest(.start)) })
    #expect(commands.contains { $0.action == .route(.rest(.pause)) })
    #expect(commands.contains { $0.action == .checkForUpdates })
    #expect(
      AppCommand.catalog(supportsFans: true).contains {
        $0.action == .route(.open(.thermal))
      })
  }

  @MainActor @Test(arguments: ["网络", " NETWORK ", "network", "网 络"])
  func searchesChineseAndEnglishAliases(query: String) {
    let search = CommandBarSearch(commands: AppCommand.catalog(supportsFans: false))
    #expect(search.results(for: query).contains { $0.action == .route(.open(.network)) })
  }

  @Test func rankingPrefersTitleAndSupportsAccentsAndFullWidthInput() {
    let commands = [
      AppCommand(
        id: "connections", title: "Connexions", symbol: "network",
        keywords: "réseau network", action: .route(.open(.connections))),
      AppCommand(
        id: "network", title: "Réseau", symbol: "network",
        keywords: "network", action: .route(.open(.network))),
    ]
    let search = CommandBarSearch(commands: commands)
    #expect(search.results(for: "reseau").first?.id == "network")
    #expect(search.results(for: "ＮＥＴＷＯＲＫ").map(\.id) == commands.map(\.id))
    #expect(search.results(for: "network reseau").count == 2)
    #expect(search.results(for: " \n ").map(\.id) == commands.map(\.id))
    #expect(search.results(for: "not-a-command").isEmpty)
    #expect(search.results(for: String(repeating: "x", count: 10_000)).isEmpty)
  }

  @MainActor @Test func commandHotKeyIsOptInAndPreservesExistingCarbonIDs() throws {
    let suite = "XStats.CommandBarTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.hotKeys[.openCommandBar] == nil)
    #expect(HotKeyAction.sleepDisplay.carbonID == 11)
    #expect(HotKeyAction.openCommandBar.carbonID == 12)
    settings.hotKeys[.openCommandBar] = HotKey(
      keyCode: 40, modifiers: [.command, .option], key: "k")
    #expect(
      AppSettings(defaults: defaults).hotKeys[.openCommandBar] == settings.hotKeys[.openCommandBar])
    let backup = settings.exportDocument()
    settings.hotKeys = [:]
    settings.apply(backup)
    #expect(settings.hotKeys[.openCommandBar] != nil)
  }
}
