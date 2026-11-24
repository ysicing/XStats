// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Testing

@testable import XStatsUI

struct AppCloneSourceSignatureTests {
  @Test func stagingCopyPreservesExtendedAttributeSignatures() async throws {
    let files = FileManager.default
    let stage = files.temporaryDirectory.appending(path: UUID().uuidString)
    try files.createDirectory(at: stage, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: stage) }
    let source = stage.appending(path: "Source.app")
    let candidate = stage.appending(path: "Clone.app")
    try makeBundle(at: source, identifier: CloneApplication.weChat.rawValue)
    let component = source.appending(path: "Contents/Frameworks/Signed.json")
    try files.createDirectory(
      at: component.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: component)
    try await AppCloneStore.run("/usr/bin/codesign", ["--sign", "-", component.path], stage: stage)
    try await AppCloneStore.run(
      "/usr/bin/codesign", ["--force", "--sign", "-", source.path], stage: stage)
    try await AppCloneStore.run(
      "/usr/bin/xattr",
      ["-wx", "com.apple.FinderInfo", "01" + String(repeating: "00", count: 31), component.path],
      stage: stage)

    try await AppCloneBuilder.copySource(source, to: candidate, stage: stage)

    try await AppCloneStore.run(
      "/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path], stage: stage)
    try await AppCloneStore.run(
      "/usr/bin/codesign",
      ["--verify", "--strict", candidate.appending(path: "Contents/Frameworks/Signed.json").path],
      stage: stage)
  }

  @Test func concurrentBuildPreservesTheActiveStage() async throws {
    let files = FileManager.default
    let scratch = files.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? files.removeItem(at: scratch) }
    let root = scratch.appending(path: "Clones")
    let stage = root.appending(path: ".stage-\(UUID().uuidString)")
    try files.createDirectory(at: stage, withIntermediateDirectories: true)
    let source = scratch.appending(path: "Source.app")
    try makeBundle(at: source, identifier: CloneApplication.brave.rawValue)
    let store = AppCloneStore(root: root)
    let clone = AppClone(id: UUID(), number: 42, application: .brave, name: "Clone")

    let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

    await #expect(throws: AppCloneStore.Failure.buildInProgress) {
      try await store.build(clone, source: source, updating: false)
    }
    #expect(files.fileExists(atPath: stage.path))

    try #require(flock(descriptor, LOCK_UN) == 0)
    await #expect(throws: AppCloneStore.Failure.untrustedSource) {
      try await store.build(clone, source: source, updating: false)
    }
    #expect(!files.fileExists(atPath: stage.path))
  }

  @Test func processUsingLegacySoftCloneProfileIsRecognizedWithoutLauncher() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppCloneStore(root: root)
    let clone = AppClone(id: UUID(), number: 44, application: .chrome, name: "Legacy")
    let other = AppClone(id: UUID(), number: 45, application: .chrome, name: "Other")
    for entry in [clone, other] {
      try makeBundle(
        at: store.bundleURL(entry), identifier: entry.bundleID,
        metadata: ["XStatsSourceIdentifier": entry.application.rawValue])
    }
    let profile = root.appending(path: clone.id.uuidString).appending(path: "Data")
    let child = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = [
      "-c", "printf R; read -r line", "clone-process", "--user-data-dir=\(profile.path)",
    ]
    child.standardInput = stdin
    child.standardOutput = stdout
    try child.run()
    defer {
      try? stdin.fileHandleForWriting.close()
      child.waitUntilExit()
    }
    #expect(try stdout.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
    let pids = [child.processIdentifier]

    #expect(await store.profileIsInUse(clone, sourcePIDs: pids))
    #expect(!(await store.profileIsInUse(other, sourcePIDs: pids)))
  }

  @Test func editorProfileCanBeIdentifiedAfterItsTemporaryAliasIsGone() throws {
    let profile = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let arguments = try #require(
      CloneApplication.visualStudioCode.profileLaunchArguments(profile: profile))
    let shortened = [
      "--user-data-dir", "/tmp/missing-editor-alias/profile", "--extensions-dir",
      profile.appending(path: "Extensions").path,
    ]
    let matched = ProfileCloneProcess.profilePaths(in: arguments).intersection(
      ProfileCloneProcess.profilePaths(in: shortened))

    #expect(matched == [profile.appending(path: "Extensions").resolvingSymlinksInPath().path])
  }

  @Test func processArgumentDecoderDoesNotReadEnvironment() {
    var count: Int32 = 2
    let encoded =
      withUnsafeBytes(of: &count, Array.init)
      + Array(
        "/Applications/例.app/Executable\0\0\0Executable\0--new-window\0HOME=/tmp/profile\0".utf8)

    #expect(ProfileCloneProcess.decodeArguments(encoded[...]) == ["Executable", "--new-window"])
  }

  @Test(arguments: [CloneApplication.visualStudioCode, .cursor, .zed])
  func editorProfilesUseIndependentApplicationData(_ application: CloneApplication) {
    let profile = URL(fileURLWithPath: "/tmp/XStats Editor Profile")
    let expected =
      application == .zed
      ? ["--user-data-dir", profile.path]
      : [
        "--user-data-dir", profile.appending(path: "UserData").path,
        "--extensions-dir", profile.appending(path: "Extensions").path,
        "--new-window",
      ]
    #expect(application.profileLaunchArguments(profile: profile) == expected)
    #expect(!application.usesChromiumProxyArgument)
  }

  @Test(arguments: [CloneApplication.chrome, .brave, .antigravityIDE, .bilibili, .firefox])
  func proxyIsStoredPerCloneAndCanBeCleared(_ application: CloneApplication) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppCloneStore(root: root)
    let first = AppClone(id: UUID(), number: 42, application: application, name: "Clone 1")
    let second = AppClone(id: UUID(), number: 43, application: application, name: "Clone 2")
    let metadata = [
      "XStatsBrowserProxyPattern": BrowserCloneProxy.endpointPattern,
      "XStatsBrowserProxyFilename": BrowserCloneProxy.filename,
    ]
    try makeBundle(at: store.bundleURL(first), identifier: first.bundleID, metadata: metadata)
    try makeBundle(at: store.bundleURL(second), identifier: second.bundleID, metadata: metadata)
    #expect(try await store.browserProxy(for: first) == nil)
    try await store.setBrowserProxy("http://127.0.0.1:7890", for: first)
    try await store.setBrowserProxy("socks5://[::1]:1080", for: second)

    let reopened = AppCloneStore(root: root)
    #expect(try await reopened.browserProxy(for: first) == "http://127.0.0.1:7890")
    #expect(try await reopened.browserProxy(for: second) == "socks5://[::1]:1080")
    for invalid in [
      "http://user:secret@localhost:1080", "http://127.0.0.1:65536",
      "http://127.0.0.1:80;direct://", "http://127.0.0.1:0",
    ] {
      await #expect(throws: AppCloneStore.Failure.invalidProxy) {
        try await reopened.setBrowserProxy(invalid, for: first)
      }
    }
    #expect(try await reopened.browserProxy(for: first) == "http://127.0.0.1:7890")
    let file = store.bundleURL(first).deletingLastPathComponent().appending(
      path: BrowserCloneProxy.filename)
    try Data(repeating: 65, count: 1024).write(to: file)
    await #expect(throws: AppCloneStore.Failure.invalidProxy) {
      try await reopened.browserProxy(for: first)
    }
    try await reopened.setBrowserProxy(nil, for: first)
    try await reopened.setBrowserProxy(nil, for: first)
    #expect(try await reopened.browserProxy(for: first) == nil)
    #expect(try await reopened.browserProxy(for: second) == "socks5://[::1]:1080")
  }

  @Test(arguments: [
    CloneApplication.chrome, .edge, .brave, .arc, .firefox, .torBrowser,
  ])
  func browserCloneUsesAnIndependentProfileAndRejectsAdHocSources(
    _ application: CloneApplication
  ) async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }
    let profile = root.appending(path: "Browser Data")
    let arguments =
      application == .firefox || application == .torBrowser
      ? ["-profile", profile.path] : ["--user-data-dir=\(profile.path)"]
    let isSoftClone = application == .brave || application == .firefox || application == .torBrowser
    #expect(application.profileLaunchArguments(profile: profile) == (isSoftClone ? arguments : nil))

    let source = root.appending(path: "Source.app")
    try makeBundle(at: source, identifier: application.rawValue)
    try await AppCloneStore.run(
      "/usr/bin/codesign", ["--force", "--sign", "-", source.path], stage: root)
    let store = AppCloneStore(root: root.appending(path: "Clones"))
    let clone = AppClone(id: UUID(), number: 42, application: application, name: "Browser")
    await #expect(throws: AppCloneStore.Failure.untrustedSource) {
      try await store.build(clone, source: source, updating: false)
    }
    #expect(!files.fileExists(atPath: store.bundleURL(clone).path))
  }

  @Test func softCloneApplicationsMatchUpstream() {
    let profile = URL(fileURLWithPath: "/tmp/XStats Profile")
    let softClones = CloneApplication.allCases.filter {
      $0.profileLaunchArguments(profile: profile) != nil
    }
    #expect(Set(softClones) == [.brave, .firefox, .torBrowser, .visualStudioCode, .cursor, .zed])
  }

  @Test(arguments: [
    CloneApplication.qq, .gemini, .antigravity, .antigravityIDE, .workBuddyAI, .bilibili, .douyin,
  ])
  func adHocSourceCannotCreateOrReplaceClone(_ application: CloneApplication) async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }
    let source = root.appending(path: "Source.app")
    try makeBundle(at: source, identifier: application.rawValue)
    try await AppCloneStore.run(
      "/usr/bin/codesign", ["--force", "--sign", "-", source.path], stage: root)
    let store = AppCloneStore(root: root.appending(path: "Clones"))
    let clone = AppClone(id: UUID(), number: 42, application: application, name: "Clone")
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

  private func makeBundle(at url: URL, identifier: String, metadata: [String: String] = [:]) throws
  {
    let files = FileManager.default
    let executable = url.appending(path: "Contents/MacOS/Fixture")
    try files.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
    var values = metadata
    values["CFBundleIdentifier"] = identifier
    values["CFBundleExecutable"] = "Fixture"
    values["CFBundlePackageType"] = "APPL"
    let plist = try PropertyListSerialization.data(
      fromPropertyList: values, format: .xml, options: 0)
    try plist.write(to: url.appending(path: "Contents/Info.plist"))
  }
}
