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
