// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import Testing
@testable import FinderDocuments

struct FinderDocumentsTests {
  @Test func createsAllFormatsWithoutOverwritingAndUsesExplicitLanguage() throws {
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
      #expect(second.lastPathComponent.hasSuffix(" 2.\(kind.rawValue)"))
      #expect(try Data(contentsOf: second) == original)
      if kind == .txt || kind == .md {
        #expect(original.isEmpty)
      } else {
        #expect(original.starts(with: [0x50, 0x4b, 0x03, 0x04]))
      }
    }
    #expect(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Document.docx").path))
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
    #expect(configuration.directoryURLs == [URL(fileURLWithPath: "/", isDirectory: true)])
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

  @Test func rejectsDisabledAndNonFileRequests() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(FinderDocumentConfiguration().directoryURLs.isEmpty)
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
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("Document.docx"), withDestinationURL: target)
    let result = try FinderDocumentCreator.create(
      .init(kind: .docx, directory: root),
      configuration: .init(enabled: true, language: .english))
    #expect(result.lastPathComponent == "Document 2.docx")
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
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
