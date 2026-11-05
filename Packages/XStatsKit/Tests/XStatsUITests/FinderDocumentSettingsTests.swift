// SPDX-License-Identifier: AGPL-3.0-or-later

import FinderDocuments
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct FinderDocumentSettingsTests {
  @Test func namingAndFormatsPersistAndRoundTripWithoutResettingOlderBackups() throws {
    let suite = "FinderDocumentSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.finderDocumentNamingMode == .fixed)
    #expect(settings.finderDocumentFormats == Set(FinderDocumentKind.allCases))
    settings.finderDocumentNamingMode = .manual
    settings.finderDocumentFixedName = "Notes"
    settings.finderDocumentFormats = [.txt, .md]
    let restored = AppSettings(defaults: defaults)
    #expect(restored.finderDocumentNamingMode == .manual)
    #expect(restored.finderDocumentFixedName == "Notes")
    #expect(restored.finderDocumentFormats == [.txt, .md])
    let backup = try JSONEncoder().encode(settings.exportDocument())
    settings.finderDocumentNamingMode = .random
    settings.finderDocumentFormats = []
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: backup))
    #expect(settings.finderDocumentNamingMode == .manual)
    #expect(settings.finderDocumentFormats == [.txt, .md])
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(settings.finderDocumentNamingMode == .manual)
    #expect(settings.finderDocumentFormats == [.txt, .md])
    settings.finderDocumentFormats = []
    #expect(AppSettings(defaults: defaults).finderDocumentFormats.isEmpty)
    let empty = try JSONEncoder().encode(settings.exportDocument())
    settings.finderDocumentFormats = [.txt]
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: empty))
    #expect(settings.finderDocumentFormats.isEmpty)
  }

  @Test func cancellingManualNameConsumesRequestWithoutCreatingFile() async throws {
    let suite = "FinderDocumentSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let store = FinderDocumentStore(directory: root.appendingPathComponent("shared"))
    let settings = AppSettings(defaults: defaults)
    settings.finderDocumentsEnabled = true
    settings.finderDocumentNamingMode = .manual
    settings.finderDocumentFormats = [.md]
    var prompts = 0
    let controller = FinderDocumentsController(settings: settings, store: store) { _, _ in
      prompts += 1
      return nil
    }
    controller.start()
    #expect(try store.configuration().namingMode == .manual)
    #expect(try store.configuration().enabledKinds == [.md])
    for _ in 0..<2 {
      let identifier = try store.enqueue(.init(kind: .md, directory: output))
      await controller.create(identifier)
      #expect(throws: (any Error).self) { try store.consume(identifier) }
    }
    #expect(prompts == 2)
    #expect(controller.error == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
  }

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
