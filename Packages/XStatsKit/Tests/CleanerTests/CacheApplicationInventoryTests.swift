// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct CacheApplicationInventoryTests {
  @Test func cancellationDoesNotReturnAnEmptyInventoryAsSuccess() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await CacheApplicationInventory.read(
        rules: RuleCatalog.rules(),
        environment: CleanEnvironment(home: "/fixture", runningBundleIdentifiers: { [] }))
    }
    do {
      _ = try await task.value
      Issue.record("Cancelled inventory must not be published")
    } catch {
      #expect(error is CancellationError)
    }
  }

  @Test func matchesIdentifiersAndBundleNamesWithoutTrackingCommandLineTools() throws {
    let rules = RuleCatalog.rules()
    let apps = [
      InstalledApp(
        url: URL(fileURLWithPath: "/Applications/Renamed.app"), name: "Renamed",
        bundleIdentifier: "com.openai.codex", version: nil, teamIdentifier: nil),
      InstalledApp(
        url: URL(fileURLWithPath: "/Applications/Telegram.app"), name: "Localized name",
        bundleIdentifier: "example.telegram", version: nil, teamIdentifier: nil),
    ]
    let inventory = CacheApplicationInventory(
      rules: rules, applications: apps, isComplete: true)
    #expect(inventory.installedRuleIDs.contains("app.codex"))
    #expect(inventory.installedRuleIDs.contains("preview.telegram"))
    #expect(!inventory.installedRuleIDs.contains("preview.zoom"))
    for id in ["preview.poetry", "preview.lima", "preview.quickLook", "preview.iconServices"] {
      #expect(try #require(rules.first { $0.id == id }).tracksApplicationPresence == false)
    }
  }
}
