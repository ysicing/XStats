// SPDX-License-Identifier: AGPL-3.0-or-later

import FinderDocuments
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct FinderDocumentSettingsTests {
  @Test func featureEnablesWithoutFolderSelectionAndPreservesBackupChoice() throws {
    let suite = "FinderDocumentSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.finderDocumentsEnabled)
    let controller = FinderDocumentsController(settings: settings)
    controller.setEnabled(true)
    #expect(settings.finderDocumentsEnabled)
    #expect(controller.error == nil)
    let saved = try JSONEncoder().encode(settings.exportDocument())
    #expect(!String(decoding: saved, as: UTF8.self).contains("finderDocumentFolders"))
    #expect(AppSettings(defaults: defaults).finderDocumentsEnabled)
    controller.setEnabled(false)
    #expect(!settings.finderDocumentsEnabled)
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: saved))
    #expect(settings.finderDocumentsEnabled)
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(settings.finderDocumentsEnabled)
  }

  @Test func creationRoutesOnlyAcceptRequestIdentifiers() throws {
    let identifier = UUID()
    #expect(
      AppDeepLink(url: FinderDocumentStore.launchURL(identifier)) == .finderCreate(identifier))
    for text in [
      "xstats://finder-create/file:///tmp", "xstats://finder-create/../../file",
      "xstats://finder-create/\(identifier)?directory=/tmp",
      "xstats://finder-create/\(identifier)/",
      "xstats://finder-create", "xstats://finder-create/\(identifier)#fragment",
    ] {
      #expect(AppDeepLink(url: try #require(URL(string: text))) == nil)
    }
  }
}
