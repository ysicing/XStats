// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import XStatsUI

struct AppCloneSourceSignatureTests {
  @Test
  func adHocSourceCannotCreateOrReplaceClone() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }
    let source = root.appending(path: "Source.app")
    try makeBundle(at: source, identifier: CloneApplication.qq.rawValue)
    try await AppCloneStore.run(
      "/usr/bin/codesign", ["--force", "--sign", "-", source.path], stage: root)
    let store = AppCloneStore(root: root.appending(path: "Clones"))
    let clone = AppClone(id: UUID(), number: 42, application: .qq, name: "QQ")
    let bundle = store.bundleURL(clone)

    await #expect(throws: AppCloneStore.Failure.untrustedSource) {
      try await store.build(clone, source: source, updating: false)
    }
    #expect(!files.fileExists(atPath: bundle.deletingLastPathComponent().path))

    try makeBundle(at: bundle, identifier: clone.bundleID)
    try JSONEncoder().encode(clone)
      .write(to: bundle.deletingLastPathComponent().appending(path: "clone.json"))
    let profile = bundle.deletingLastPathComponent().appending(path: "Data")
    try files.createDirectory(at: profile, withIntermediateDirectories: false)
    let marker = profile.appending(path: "marker")
    let contents = Data("preserved".utf8)
    try contents.write(to: marker)

    await #expect(throws: AppCloneStore.Failure.untrustedSource) {
      try await store.build(clone, source: source, updating: true)
    }
    #expect(AppCloneStore.hasIdentity(bundle, clone.bundleID))
    #expect(try Data(contentsOf: marker) == contents)
  }

  @Test
  func buildClearsOnlyUnregisteredCloneAndStageDirectories() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? files.removeItem(at: root) }
    let store = AppCloneStore(root: root.appending(path: "Clones"))
    let stage = store.root.appending(path: ".stage-interrupted")
    let orphan = store.root.appending(path: UUID().uuidString)
    let registered = store.root.appending(path: UUID().uuidString)
    let registeredStage = store.root.appending(path: ".stage-registered")
    let other = store.root.appending(path: "Other")
    let stageFile = store.root.appending(path: ".stage-file")
    let linkedStage = store.root.appending(path: ".stage-link")
    for directory in [stage, orphan, registered, registeredStage, other] {
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    for directory in [registered, registeredStage] {
      try Data().write(to: directory.appending(path: "clone.json"))
    }
    try Data().write(to: stageFile)
    try files.createSymbolicLink(at: linkedStage, withDestinationURL: other)
    let source = root.appending(path: "Source.app")
    try makeBundle(at: source, identifier: CloneApplication.qq.rawValue)
    let clone = AppClone(id: UUID(), number: 42, application: .qq, name: "QQ")

    await #expect(throws: AppCloneStore.Failure.invalidClone) {
      try await store.build(clone, source: source, updating: true)
    }

    #expect(!files.fileExists(atPath: stage.path))
    #expect(!files.fileExists(atPath: orphan.path))
    for preserved in [
      registered.appending(path: "clone.json"), registeredStage.appending(path: "clone.json"),
      other, stageFile, linkedStage,
    ] {
      #expect(files.fileExists(atPath: preserved.path))
    }
  }

  @Test
  func trashIncludingDataMovesOnlySelectedCloneDirectory() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? files.removeItem(at: root) }
    let store = AppCloneStore(root: root.appending(path: "Clones"))
    let clone = AppClone(id: UUID(), number: 42, application: .qq, name: "QQ")
    let bundle = store.bundleURL(clone)
    let directory = store.root.appending(path: clone.id.uuidString)
    let other = store.root.appending(path: UUID().uuidString)
    let trash = root.appending(path: "Trash")
    try makeBundle(at: bundle, identifier: clone.bundleID)
    try files.createDirectory(
      at: directory.appending(path: "Data"), withIntermediateDirectories: false)
    try JSONEncoder().encode(clone).write(to: directory.appending(path: "clone.json"))
    try files.createDirectory(at: other, withIntermediateDirectories: false)
    try files.createDirectory(at: trash, withIntermediateDirectories: false)

    let trashed = trash.appending(path: clone.id.uuidString)
    try await store.moveToTrashIncludingData(clone) { item in
      #expect(item.path == directory.path)
      try FileManager.default.moveItem(at: item, to: trashed)
    }

    #expect(!files.fileExists(atPath: directory.path))
    #expect(files.fileExists(atPath: other.path))
    for name in [clone.bundleFilename, "Data", "clone.json"] {
      #expect(files.fileExists(atPath: trashed.appending(path: name).path))
    }
  }

  @Test
  func trashIncludingDataRejectsMismatchedIdentityAndSymlinkDirectory() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? files.removeItem(at: root) }
    let store = AppCloneStore(root: root.appending(path: "Clones"))
    let clone = AppClone(id: UUID(), number: 42, application: .qq, name: "QQ")
    let bundle = store.bundleURL(clone)
    try makeBundle(at: bundle, identifier: CloneApplication.qq.rawValue)

    await #expect(throws: AppCloneStore.Failure.invalidClone) {
      try await store.moveToTrashIncludingData(clone) { _ in
        Issue.record("Unexpected trash operation")
      }
    }
    #expect(AppCloneStore.hasIdentity(bundle, CloneApplication.qq.rawValue))

    let linkedClone = AppClone(id: UUID(), number: 43, application: .qq, name: "QQ")
    let external = root.appending(path: "External")
    let externalBundle = external.appending(path: linkedClone.bundleFilename)
    try makeBundle(at: externalBundle, identifier: linkedClone.bundleID)
    let link = store.root.appending(path: linkedClone.id.uuidString)
    try files.createSymbolicLink(at: link, withDestinationURL: external)
    await #expect(throws: AppCloneStore.Failure.invalidClone) {
      try await store.moveToTrashIncludingData(linkedClone) { _ in
        Issue.record("Unexpected trash operation")
      }
    }
    #expect(AppCloneStore.hasIdentity(externalBundle, linkedClone.bundleID))
  }

  private func makeBundle(at url: URL, identifier: String) throws {
    let files = FileManager.default
    let executable = url.appending(path: "Contents/MacOS/Fixture")
    try files.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
        "CFBundlePackageType": "APPL",
      ], format: .xml, options: 0)
    try plist.write(to: url.appending(path: "Contents/Info.plist"))
  }
}
