// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import Testing
@testable import FinderDocuments

struct FinderDocumentsTests {
  @Test func nativeFormatsRecognizeInstalledApplicationIdentifiers() {
    let installed: Set<String> = ["com.apple.Keynote", "com.apple.Numbers"]
    #expect(FinderDocumentKind.key.isAvailable(applicationIsInstalled: installed.contains))
    #expect(FinderDocumentKind.numbers.isAvailable(applicationIsInstalled: installed.contains))
    #expect(!FinderDocumentKind.pages.isAvailable(applicationIsInstalled: installed.contains))
    #expect(FinderDocumentKind.txt.isAvailable(applicationIsInstalled: { _ in false }))
    #expect(
      FinderDocumentKind.key.isAvailable {
        $0 == "com.apple.iWork.Keynote"
      })
    #expect(!FinderDocumentKind.key.isAvailable(applicationIsInstalled: { _ in false }))
  }

  @Test func decodesLegacyConfigurationAndPreservesEmptyFormatSelection() throws {
    let legacy = Data(#"{"enabled":true,"languageCode":"en"}"#.utf8)
    let configuration = try JSONDecoder().decode(FinderDocumentConfiguration.self, from: legacy)
    #expect(configuration.namingMode == .randomString)
    #expect(configuration.enabledKinds == Set(FinderDocumentKind.allCases))
    let empty = FinderDocumentConfiguration(
      enabled: true, namingMode: .random, enabledKinds: [])
    let decoded = try JSONDecoder().decode(
      FinderDocumentConfiguration.self, from: JSONEncoder().encode(empty))
    #expect(decoded == empty)
    let future = Data(
      #"{"enabled":true,"languageCode":"en","namingMode":"future","enabledKinds":["txt","future"]}"#
        .utf8)
    let compatible = try JSONDecoder().decode(FinderDocumentConfiguration.self, from: future)
    #expect(compatible.namingMode == .randomString)
    #expect(compatible.enabledKinds == [.txt])
    for mode in ["manual", "fixed", "random", "randomString"] {
      let legacy = Data(
        """
        {"enabled":true,"languageCode":"en","namingMode":"\(mode)","fixedName":"Notes"}
        """.utf8)
      let migrated = try JSONDecoder().decode(FinderDocumentConfiguration.self, from: legacy)
      #expect(migrated.namingMode == (mode == "random" ? .random : .randomString))
      let encoded = try JSONEncoder().encode(migrated)
      #expect(!String(decoding: encoded, as: UTF8.self).contains("fixedName"))
    }
  }

  @Test(arguments: [FinderDocumentNamingMode.randomString, .random])
  func createsRandomNamesWithoutOverwriting(mode: FinderDocumentNamingMode) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = FinderDocumentConfiguration(enabled: true, namingMode: mode)
    let request = FinderDocumentRequest(kind: .md, directory: root)
    let first = try FinderDocumentCreator.create(request, configuration: configuration)
    let second = try FinderDocumentCreator.create(request, configuration: configuration)
    #expect(first != second)
    for url in [first, second] {
      let name = url.deletingPathExtension().lastPathComponent
      if mode == .randomString {
        #expect(name.utf8.count == 8)
        #expect(
          name.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          })
      } else {
        #expect(UUID(uuidString: name) != nil)
        #expect(name == name.lowercased())
      }
      #expect(url.pathExtension == "md")
      #expect(try Data(contentsOf: url).isEmpty)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
  }

  @Test func shortRandomNamesAlwaysUseEightASCIIAlphanumericCharacters() {
    let configuration = FinderDocumentConfiguration(namingMode: .randomString)
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
    for _ in 0..<128 {
      let name = configuration.baseName()
      #expect(name.utf8.count == 8)
      #expect(name.utf8.allSatisfy(allowed.contains))
    }
  }

  @Test(arguments: [
    "", ".", "..", "../escape", "a/b", "a\\b", "a:b", "a\u{0}b", "a\nb",
    String(repeating: "文", count: 74),
  ])
  func rejectsUnsafeBaseNames(name: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: FinderDocumentError.invalidName) {
      try FinderDocumentCreator.create(
        .init(kind: .txt, directory: root), configuration: .init(enabled: true),
        generateName: { name })
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test func rejectsDeselectedFormatsInQueueAndCreator() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FinderDocumentStore(directory: root.appendingPathComponent("shared"))
    let configuration = FinderDocumentConfiguration(enabled: true, enabledKinds: [.txt])
    try store.save(configuration)
    let request = FinderDocumentRequest(kind: .md, directory: root)
    #expect(throws: FinderDocumentError.invalidRequest) { try store.enqueue(request) }
    #expect(throws: FinderDocumentError.invalidRequest) {
      try FinderDocumentCreator.create(request, configuration: configuration)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["shared"])
  }

  @Test func createsAllFormatsWithoutOverwriting() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = FinderDocumentConfiguration(
      enabled: true, language: .english)
    #expect(
      Set(FinderDocumentKind.allCases.map(\.rawValue))
        == ["docx", "xlsx", "pptx", "txt", "md", "key", "numbers", "pages"])
    for kind in FinderDocumentKind.allCases {
      let request = FinderDocumentRequest(kind: kind, directory: root)
      let first = try FinderDocumentCreator.create(request, configuration: configuration)
      let original = try Data(contentsOf: first)
      let second = try FinderDocumentCreator.create(request, configuration: configuration)
      #expect(first != second)
      #expect(first.pathExtension == kind.rawValue)
      #expect(second.pathExtension == kind.rawValue)
      #expect(try Data(contentsOf: second) == original)
      if kind == .txt || kind == .md {
        #expect(original.isEmpty)
      } else {
        #expect(original.starts(with: [0x50, 0x4b, 0x03, 0x04]))
      }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 16)
  }

  @Test func nativeTemplatesContainIWorkArchivesAndPreserveSourceBytes() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifiers: [FinderDocumentKind: String] = [
      .key: "com.apple.iWork.Keynote", .numbers: "com.apple.iWork.Numbers",
      .pages: "com.apple.iWork.Pages",
    ]
    for (kind, identifier) in identifiers {
      #expect(kind.applicationBundleIdentifier == identifier)
      let result = try FinderDocumentCreator.create(
        .init(kind: kind, directory: root), configuration: .init(enabled: true, language: .english))
      let data = try Data(contentsOf: result)
      #expect(data.range(of: Data("Index/Document.iwa".utf8)) != nil)
      #expect(data.range(of: Data("Metadata/Properties.plist".utf8)) != nil)
      #expect(data.range(of: Data("[Content_Types].xml".utf8)) == nil)
      let template = try #require(
        Bundle.module.url(
          forResource: "blank", withExtension: kind.rawValue, subdirectory: "Templates"))
      #expect(data == (try Data(contentsOf: template)))
    }
    for kind in FinderDocumentKind.allCases where identifiers[kind] == nil {
      #expect(kind.applicationBundleIdentifier == nil)
    }
  }

  @Test func allowsUnselectedFoldersAndResolvedDirectoryLinks() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = FinderDocumentConfiguration(enabled: true)
    #expect(
      configuration.directoryURLs(mountedVolumes: []) == [
        URL(fileURLWithPath: "/", isDirectory: true)
      ])
    for name in ["first", "second/nested"] {
      let directory = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let result = try FinderDocumentCreator.create(
        .init(kind: .md, directory: directory), configuration: configuration)
      #expect(result.deletingLastPathComponent().path == directory.path)
      #expect(try Data(contentsOf: result).isEmpty)
    }
    let target = root.appendingPathComponent("second/nested")
    let link = root.appendingPathComponent("linked-folder")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let result = try FinderDocumentCreator.create(
      .init(kind: .txt, directory: link), configuration: configuration)
    #expect(result.deletingLastPathComponent().path == target.path)
  }

  @Test func registersMountedVolumesAndClearsAllRootsWhenDisabled() throws {
    let root = URL(fileURLWithPath: "/", isDirectory: true)
    let networkVolume = URL(fileURLWithPath: "/Volumes/workdata", isDirectory: true)
    let externalVolume = URL(fileURLWithPath: "/Volumes/External Disk", isDirectory: true)
    let remote = try #require(URL(string: "file://example.invalid/share"))
    let web = try #require(URL(string: "https://example.invalid/share"))
    let volumes = [root, networkVolume, externalVolume, networkVolume, remote, web]
    var configuration = FinderDocumentConfiguration(enabled: true)
    #expect(
      configuration.directoryURLs(mountedVolumes: volumes) == [
        root, networkVolume, externalVolume,
      ])
    #expect(
      configuration.directoryURLs(mountedVolumes: [externalVolume]) == [root, externalVolume])
    configuration.enabled = false
    #expect(configuration.directoryURLs(mountedVolumes: volumes).isEmpty)
  }

  @Test func rejectsDisabledAndNonFileRequests() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(FinderDocumentConfiguration().directoryURLs(mountedVolumes: []).isEmpty)
    #expect(throws: FinderDocumentError.self) {
      try FinderDocumentCreator.create(
        .init(kind: .txt, directory: root), configuration: .init(enabled: false))
    }
    for address in ["https://example.invalid/folder", "file://example.invalid/folder"] {
      let directory = try #require(URL(string: address))
      #expect(!FinderDocumentConfiguration(enabled: true).permits(directory))
      #expect(throws: FinderDocumentError.self) {
        try FinderDocumentCreator.create(
          .init(kind: .txt, directory: directory), configuration: .init(enabled: true))
      }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test func respectsDirectoryWritePermissionsAndRejectsFileTargets() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let readonly = root.appendingPathComponent("readonly")
    try FileManager.default.createDirectory(at: readonly, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readonly.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: readonly.path)
    }
    #expect(throws: POSIXError.self) {
      try FinderDocumentCreator.create(
        .init(kind: .md, directory: readonly), configuration: .init(enabled: true))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: readonly.path).isEmpty)
    let file = root.appendingPathComponent("existing.txt")
    try Data("keep".utf8).write(to: file)
    #expect(throws: POSIXError.self) {
      try FinderDocumentCreator.create(
        .init(kind: .txt, directory: file), configuration: .init(enabled: true))
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
  }

  @Test func existingDestinationSymlinkIsNeverOverwritten() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("original")
    try Data("keep".utf8).write(to: target)
    try Data("existing".utf8).write(to: root.appendingPathComponent("Existing.docx"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("Symlink1.docx"), withDestinationURL: target)
    var names = ["Existing", "Symlink1", "NewName1"].makeIterator()
    let result = try FinderDocumentCreator.create(
      .init(kind: .docx, directory: root),
      configuration: .init(enabled: true, language: .english),
      generateName: { names.next() ?? "Fallback" })
    #expect(result.lastPathComponent == "NewName1.docx")
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    #expect(
      try String(contentsOf: root.appendingPathComponent("Existing.docx"), encoding: .utf8)
        == "existing")
    #expect(throws: FinderDocumentError.nameLimit) {
      try FinderDocumentCreator.create(
        .init(kind: .docx, directory: root), configuration: .init(enabled: true),
        generateName: { "Existing" })
    }
  }

  @Test func requestsAreOneUseBoundedAndExpire() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FinderDocumentStore(directory: root.appendingPathComponent("shared"))
    try store.save(.init(enabled: true))
    let identifier = try store.enqueue(.init(kind: .docx, directory: root))
    #expect(try store.consume(identifier).kind == .docx)
    #expect(throws: (any Error).self) { try store.consume(identifier) }
    let expired = try store.enqueue(
      .init(kind: .txt, directory: root, createdAt: Date(timeIntervalSince1970: 0)))
    #expect(throws: FinderDocumentError.self) { try store.consume(expired) }
    let large = UUID()
    try Data(repeating: 0, count: 16_385).write(
      to: store.directory.appendingPathComponent("Requests/\(large).json"))
    #expect(throws: FinderDocumentError.self) { try store.consume(large) }
    try store.save(.init(enabled: false))
    #expect(throws: FinderDocumentError.self) {
      try store.enqueue(.init(kind: .txt, directory: root))
    }
  }

  @Test func requestSymlinksCannotReadOrRemoveTheirTargets() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FinderDocumentStore(directory: root.appendingPathComponent("shared"))
    try store.save(.init(enabled: true))
    let identifier = try store.enqueue(.init(kind: .txt, directory: root))
    let request = store.directory.appendingPathComponent("Requests/\(identifier).json")
    let target = root.appendingPathComponent("private")
    try Data("keep".utf8).write(to: target)
    try FileManager.default.removeItem(at: request)
    try FileManager.default.createSymbolicLink(at: request, withDestinationURL: target)
    #expect(throws: (any Error).self) { try store.consume(identifier) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FinderDocumentsTests-\(UUID())"
    )
    .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
