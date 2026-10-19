// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct AgentDataFeatureTests {
  @Test func defaultsOffAndExplicitChoicePersistsIndependentlyOfCleaner() throws {
    let suite = "AgentDataFeatureTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.agentDataEnabled)
    settings.cleanerEnabled = false
    settings.agentDataEnabled = true
    #expect(!settings.cleanerEnabled)
    #expect(AppSettings(defaults: defaults).agentDataEnabled)
    settings.cleanerEnabled = true
    settings.agentDataEnabled = false
    #expect(settings.cleanerEnabled)
    #expect(!AppSettings(defaults: defaults).agentDataEnabled)
  }

  @Test func backupRoundTripsAndMissingFieldPreservesCurrentChoice() throws {
    let suite = "AgentDataFeatureTests.backup.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let oldDocument = try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8))
    settings.apply(oldDocument)
    #expect(!settings.agentDataEnabled)
    settings.agentDataEnabled = true
    let saved = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    settings.agentDataEnabled = false
    settings.apply(saved)
    #expect(settings.agentDataEnabled)
    settings.apply(oldDocument)
    #expect(settings.agentDataEnabled)
    var disabled = SettingsDocument()
    disabled.agentDataEnabled = false
    settings.apply(disabled)
    #expect(!settings.agentDataEnabled)
  }
}
