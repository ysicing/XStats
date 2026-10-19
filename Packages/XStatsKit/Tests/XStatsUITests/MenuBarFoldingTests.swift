// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import XStatsUI

@MainActor
struct MenuBarFoldingTests {
  @Test(arguments: [false, true])
  func manualSelectionSurvivesRestart(collapsed: Bool) throws {
    _ = NSApplication.shared
    let suite = "MenuBarFoldingTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarFoldingEnabled = true
    let controller = MenuBarFoldingController(settings: settings)
    defer { controller.stop() }
    controller.start()
    #expect(!controller.isCollapsed)
    controller.toggle()
    if !collapsed { controller.toggle() }
    #expect(controller.isCollapsed == collapsed)
    controller.stop()

    let restored = MenuBarFoldingController(settings: AppSettings(defaults: defaults))
    defer { restored.stop() }
    restored.start()
    #expect(restored.isCollapsed == collapsed)
  }

  @Test func screenChangeTemporarilyExpandsWithoutForgettingManualSelection() throws {
    _ = NSApplication.shared
    let suite = "MenuBarFoldingTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarFoldingEnabled = true
    let controller = MenuBarFoldingController(settings: settings)
    defer { controller.stop() }
    controller.start()
    controller.toggle()
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    #expect(!controller.isCollapsed)
    controller.stop()

    let restored = MenuBarFoldingController(settings: AppSettings(defaults: defaults))
    defer { restored.stop() }
    restored.start()
    #expect(restored.isCollapsed)
  }

  @Test func foldingIsOptInAndLocalToThisMac() throws {
    let suite = "MenuBarFoldingTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.menuBarFoldingEnabled)
    #expect(!settings.menuBarFoldingCollapsed)
    settings.menuBarFoldingEnabled = true
    settings.menuBarFoldingCollapsed = true
    #expect(AppSettings(defaults: defaults).menuBarFoldingEnabled)
    let document = settings.exportDocument()
    settings.menuBarFoldingEnabled = false
    settings.menuBarFoldingCollapsed = false
    settings.apply(document)
    #expect(!settings.menuBarFoldingEnabled)
    #expect(!settings.menuBarFoldingCollapsed)
    #expect(!AppSettings(defaults: defaults).menuBarFoldingEnabled)
    #expect(!AppSettings(defaults: defaults).menuBarFoldingCollapsed)
  }
}
