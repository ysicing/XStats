// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct MenuBarFoldingTests {
  @Test func foldingIsOptInAndLocalToThisMac() throws {
    let suite = "MenuBarFoldingTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.menuBarFoldingEnabled)
    settings.menuBarFoldingEnabled = true
    #expect(AppSettings(defaults: defaults).menuBarFoldingEnabled)
    let document = settings.exportDocument()
    settings.menuBarFoldingEnabled = false
    settings.apply(document)
    #expect(!settings.menuBarFoldingEnabled)
    #expect(!AppSettings(defaults: defaults).menuBarFoldingEnabled)
  }
}
