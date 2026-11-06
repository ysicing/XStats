// SPDX-License-Identifier: AGPL-3.0-or-later

import FinderDocuments
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct FinderDocumentSettingsTests {
  @Test(arguments: [FinderDocumentNamingMode.randomString, .random])
  func namingAndFormatsPersistAndRoundTripWithoutResettingOlderBackups(
    mode: FinderDocumentNamingMode
  ) throws {
    let suite = "FinderDocumentSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.finderDocumentNamingMode == .randomString)
    #expect(settings.finderDocumentFormats == Set(FinderDocumentKind.allCases))
    settings.finderDocumentNamingMode = mode
    settings.finderDocumentFormats = [.txt, .md]
    let restored = AppSettings(defaults: defaults)
    #expect(restored.finderDocumentNamingMode == mode)
    #expect(restored.finderDocumentFormats == [.txt, .md])
    let backup = try JSONEncoder().encode(settings.exportDocument())
    settings.finderDocumentNamingMode = mode == .random ? .randomString : .random
    settings.finderDocumentFormats = []
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: backup))
    #expect(settings.finderDocumentNamingMode == mode)
    #expect(settings.finderDocumentFormats == [.txt, .md])
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(settings.finderDocumentNamingMode == mode)
    #expect(settings.finderDocumentFormats == [.txt, .md])
    settings.finderDocumentFormats = []
    #expect(AppSettings(defaults: defaults).finderDocumentFormats.isEmpty)
    let empty = try JSONEncoder().encode(settings.exportDocument())
    settings.finderDocumentFormats = [.txt]
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: empty))
    #expect(settings.finderDocumentFormats.isEmpty)
  }

  @Test(arguments: ["manual", "fixed", "random", "future"])
  func legacyNamingMigratesWithoutRestoringFixedNames(mode: String) throws {
    let suite = "FinderDocumentSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(mode, forKey: "finderDocumentNamingMode")
    defaults.set("Notes", forKey: "finderDocumentFixedName")
    let settings = AppSettings(defaults: defaults)
    let expected: FinderDocumentNamingMode = mode == "random" ? .random : .randomString
    #expect(settings.finderDocumentNamingMode == expected)
    settings.finderDocumentNamingMode = expected == .random ? .randomString : .random
    let legacy = Data(
      """
      {"finderDocumentNamingMode":"\(mode)","finderDocumentFixedName":"Notes"}
      """.utf8)
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: legacy))
    #expect(settings.finderDocumentNamingMode == expected)
    #expect(AppSettings(defaults: defaults).finderDocumentNamingMode == expected)
    #expect(settings.exportDocument().finderDocumentNamingMode == expected.rawValue)
    let exported = try JSONEncoder().encode(settings.exportDocument())
    #expect(!String(decoding: exported, as: UTF8.self).contains("finderDocumentFixedName"))
  }

  @Test(arguments: [FinderDocumentNamingMode.randomString, .random])
  func randomNamingCreatesAndSelectsFilesWithoutOverwriting(
    mode: FinderDocumentNamingMode
  ) async throws {
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
    settings.finderDocumentNamingMode = mode
    settings.finderDocumentFormats = [.md]
    var presented: [URL] = []
    let controller = FinderDocumentsController(settings: settings, store: store) { url in
      #expect(url.deletingLastPathComponent().path == output.path)
      #expect(url.pathExtension == "md")
      #expect(FileManager.default.fileExists(atPath: url.path))
      let name = url.deletingPathExtension().lastPathComponent
      if mode == .randomString {
        #expect(name.utf8.count == 8)
        #expect(
          name.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          })
      } else {
        #expect(UUID(uuidString: name) != nil)
      }
      presented.append(url)
    }
    controller.start()
    #expect(try store.configuration().namingMode == mode)
    #expect(try store.configuration().enabledKinds == [.md])
    for _ in 0..<2 {
      let identifier = try store.enqueue(.init(kind: .md, directory: output))
      await controller.create(identifier)
      #expect(throws: (any Error).self) { try store.consume(identifier) }
    }
    #expect(presented.count == 2)
    #expect(Set(presented).count == 2)
    #expect(controller.error == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).count == 2)
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
