// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Testing
@testable import XStatsUI

struct LauncherApplicationDirectoriesTests {
  private let suite = "LauncherApplicationDirectoriesTests.\(UUID())"
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString)

  @Test func bookmarksRoundTripDeduplicateCanonicalPathsAndRemove() throws {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    let center = NotificationCenter()
    let store = LauncherApplicationDirectories(defaults: defaults, notificationCenter: center)
    #expect(try store.add(directory))
    #expect(try store.add(alias) == false)
    #expect(try store.add(directory.appendingPathComponent("../Applications")) == false)
    let saved = try #require(store.directories.first)
    #expect(saved.path == directory.resolvingSymlinksInPath().standardizedFileURL.path)
    #expect(saved.bookmark.isEmpty == false)
    let restored = LauncherApplicationDirectories(defaults: defaults, notificationCenter: center)
    #expect(restored.directories == [saved])
    try restored.withResolvedDirectories { urls, incomplete in
      #expect(incomplete == false)
      #expect(urls.map(\.path) == [saved.path])
    }
    #expect(try restored.remove(saved.id))
    #expect(restored.directories.isEmpty)
    #expect(try restored.remove(saved.id) == false)
    #expect(store.directories.isEmpty)
  }

  @Test func rejectsApplicationPackagesAndLimitsCustomDirectories() throws {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defer { try? FileManager.default.removeItem(at: root) }
    let application = root.appendingPathComponent("Container.APP")
    let contents = application.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let store = LauncherApplicationDirectories(
      defaults: defaults, notificationCenter: NotificationCenter())
    #expect(throws: LauncherApplicationDirectories.DirectoryError.applicationBundle) {
      try store.add(application)
    }
    #expect(throws: LauncherApplicationDirectories.DirectoryError.applicationBundle) {
      try store.add(contents)
    }
    for index in 0..<LauncherApplicationDirectories.maximumCount {
      let directory = root.appendingPathComponent("Directory-\(index)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      #expect(try store.add(directory))
    }
    let overflow = root.appendingPathComponent("Overflow")
    try FileManager.default.createDirectory(at: overflow, withIntermediateDirectories: true)
    #expect(throws: LauncherApplicationDirectories.DirectoryError.limitReached) {
      try store.add(overflow)
    }
    #expect(store.directories.count == 16)
    #expect(try store.add(root.appendingPathComponent("Directory-0")) == false)
  }

  @Test func defaultsRemainBuiltInAndCannotBeAddedAgain() throws {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = LauncherApplicationDirectories(
      defaults: defaults, notificationCenter: NotificationCenter())
    #expect(
      CommandBarApplications.directories.map(\.path) == [
        "/Applications", NSHomeDirectory() + "/Applications", "/System/Applications",
        "/System/Library/CoreServices/Applications",
      ])
    #expect(try store.add(URL(fileURLWithPath: "/Applications")) == false)
    #expect(store.directories.isEmpty)
  }

  @Test func onlyActualDirectoryChangesPostInvalidation() async throws {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let center = NotificationCenter()
    let store = LauncherApplicationDirectories(defaults: defaults, notificationCenter: center)
    try await confirmation(expectedCount: 2) { changed in
      let observer = center.addObserver(
        forName: .launcherApplicationsChanged, object: nil, queue: nil
      ) { _ in changed() }
      defer { center.removeObserver(observer) }
      #expect(try store.add(root))
      #expect(try store.add(root) == false)
      let id = try #require(store.directories.first?.id)
      #expect(try store.remove(id))
      #expect(try store.remove(id) == false)
    }
  }

  @MainActor @Test func bookmarksAndPathsStayOutOfSettingsBackups() throws {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = LauncherApplicationDirectories(
      defaults: defaults, notificationCenter: NotificationCenter())
    try store.add(root)
    let backup = try JSONEncoder().encode(AppSettings(defaults: defaults).exportDocument())
    let text = String(decoding: backup, as: UTF8.self)
    #expect(text.contains(LauncherApplicationDirectories.defaultsKey) == false)
    #expect(text.contains(root.lastPathComponent) == false)
  }

  @Test func missingCustomDirectoryDoesNotPruneExistingLayout() throws {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defer { try? FileManager.default.removeItem(at: root) }
    let custom = root.appendingPathComponent("External")
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    let store = LauncherApplicationDirectories(
      defaults: defaults, notificationCenter: NotificationCenter())
    try store.add(custom)
    #expect(
      try CommandBarApplications.scanResult(directories: [], customDirectories: store).isTruncated
        == false)
    try FileManager.default.removeItem(at: custom)
    let scanned = try CommandBarApplications.scanResult(directories: [], customDirectories: store)
    #expect(scanned.isTruncated)
    #expect(store.directories.count == 1)
    var layout = LaunchpadLayout(pages: [[.app("application.offline")]])
    layout.reconcile(
      appIDs: scanned.commands.map(\.id), capacity: 20, pruneMissing: !scanned.isTruncated)
    #expect(layout.pages == [[.app("application.offline")]])
    #expect(try CommandBarApplications.scanResult(directories: [custom]).isTruncated)
    #expect(try CommandBarApplications.scanResult(directories: []).isTruncated == false)
    let id = try #require(store.directories.first?.id)
    try store.remove(id)
    #expect(
      try CommandBarApplications.scanResult(directories: [], customDirectories: store).isTruncated
        == false)
  }

  @Test(.enabled(if: geteuid() != 0))
  func unreadableCustomDirectoryDoesNotPruneExistingLayout() throws {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = LauncherApplicationDirectories(
      defaults: defaults, notificationCenter: NotificationCenter())
    try store.add(root)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    let scanned = try CommandBarApplications.scanResult(directories: [], customDirectories: store)
    #expect(scanned.isTruncated)
    #expect(store.directories.count == 1)
    var layout = LaunchpadLayout(pages: [[.app("application.unreadable")]])
    layout.reconcile(
      appIDs: scanned.commands.map(\.id), capacity: 20, pruneMissing: !scanned.isTruncated)
    #expect(layout.pages == [[.app("application.unreadable")]])
    #expect(try CommandBarApplications.scanResult(directories: [root]).isTruncated)
  }

  @Test func corruptBookmarksDoNotMakeScansAuthoritative() throws {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let entry = LauncherApplicationDirectories.Directory(
      id: UUID(), path: "/unavailable", bookmark: Data("invalid".utf8))
    defaults.set(
      try JSONEncoder().encode([entry]), forKey: LauncherApplicationDirectories.defaultsKey)
    let store = LauncherApplicationDirectories(
      defaults: defaults, notificationCenter: NotificationCenter())
    #expect(
      try CommandBarApplications.scanResult(directories: [], customDirectories: store).isTruncated)
    #expect(store.directories == [entry])
    defaults.set(Data("corrupt".utf8), forKey: LauncherApplicationDirectories.defaultsKey)
    #expect(
      try CommandBarApplications.scanResult(directories: [], customDirectories: store).isTruncated)
  }

  @Test(.enabled(if: geteuid() != 0))
  func unreadableSubdirectoryMakesAnOtherwiseReadableScanIncomplete() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let restricted = root.appendingPathComponent("Restricted")
    try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: restricted.path)
    }
    #expect(try CommandBarApplications.scanResult(directories: [root]).isTruncated)
  }

  @Test(arguments: [false, true])
  func cancellationPropagatesThroughScanningAndDirectoryResolution(custom: Bool) async {
    let scan = Task {
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let store = LauncherApplicationDirectories(
        defaults: defaults, notificationCenter: NotificationCenter())
      withUnsafeCurrentTask { $0?.cancel() }
      if !custom { return try CommandBarApplications.scanResult(directories: []) }
      return try CommandBarApplications.scanResult(directories: [], customDirectories: store)
    }
    await #expect(throws: CancellationError.self) { try await scan.value }
  }
}
