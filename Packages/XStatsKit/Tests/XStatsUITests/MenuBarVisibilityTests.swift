// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

struct MenuBarVisibilityTests {
  private static let ownID = "work.12306.xstats.app"

  @Test func preservesUnknownFieldsAndSystemEntries() throws {
    let rows: [Any] = [
      ["module": ["_0": "WiFi"]], ["isAllowed": true, "future": "system"],
      ["bundle": ["_0": "example.app"]], ["isAllowed": true, "future": [1, 2, 3]],
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: rows, format: .binary, options: 0)
    let changed = try MenuBarApplicationList(data: data).updating(["example.app": false])
    let decoded = try #require(
      PropertyListSerialization.propertyList(from: changed, format: nil) as? [Any])
    #expect((decoded[1] as? NSDictionary) == (rows[1] as? NSDictionary))
    #expect((decoded[3] as? [String: Any])?["future"] as? [Int] == [1, 2, 3])
    #expect(try MenuBarApplicationList(data: changed).states == ["example.app": false])
  }

  @Test func rejectsMalformedAndDuplicateRecords() throws {
    let key = ["bundle": ["_0": "example.app"]]
    let cases: [[Any]] = [
      [key], [key, ["isAllowed": "false"]], [key, ["isAllowed": 1]],
      [key, ["isAllowed": true], key, ["isAllowed": false]],
    ]
    for rows in cases {
      let data = try PropertyListSerialization.data(
        fromPropertyList: rows, format: .binary, options: 0)
      #expect(throws: MenuBarVisibilityError.self) { try MenuBarApplicationList(data: data) }
    }
  }

  @Test func collapseAndRestoreOnlyOwnedChanges() async throws {
    let fixture = try Fixture(["example.a": true, "example.b": false, "example.c": true])
    defer { fixture.cleanUp() }
    try await fixture.store.collapse(["example.a", "example.b"], ownBundleID: Self.ownID)
    #expect(try fixture.states() == ["example.a": false, "example.b": false, "example.c": true])
    // 用户在本次折叠之外修改了另一应用；恢复不能覆盖它。
    try fixture.set("example.c", allowed: false)
    try await fixture.store.restore()
    #expect(try fixture.states() == ["example.a": true, "example.b": false, "example.c": false])
    #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
  }

  @Test func recoverySurvivesStoreRecreation() async throws {
    let fixture = try Fixture(["example.a": true])
    defer { fixture.cleanUp() }
    try await fixture.store.collapse(["example.a"], ownBundleID: Self.ownID)
    let restarted = MenuBarVisibilityStore(client: fixture.client, journal: fixture.journal)
    try await restarted.restore()
    #expect(try fixture.states()["example.a"] == true)
  }

  @Test func ambiguousWriteFailureKeepsRecoveryRecord() async throws {
    let fixture = try Fixture(["example.a": true])
    defer { fixture.cleanUp() }
    fixture.failAfterNextWrite()
    await #expect(throws: MenuBarVisibilityError.self) {
      try await fixture.store.collapse(["example.a"], ownBundleID: Self.ownID)
    }
    #expect(try fixture.states()["example.a"] == false)
    #expect(FileManager.default.fileExists(atPath: fixture.journal.path))
    try await fixture.store.restore()
    #expect(try fixture.states()["example.a"] == true)
  }

  @Test func failedRecoveryRemainsRetryable() async throws {
    let fixture = try Fixture(["example.a": true])
    defer { fixture.cleanUp() }
    try await fixture.store.collapse(["example.a"], ownBundleID: Self.ownID)
    fixture.failAfterNextWrite()
    await #expect(throws: MenuBarVisibilityError.self) { try await fixture.store.restore() }
    #expect(FileManager.default.fileExists(atPath: fixture.journal.path))
    try await fixture.store.restore()
    #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
  }

  @Test(arguments: ["missing.app", "com.apple.ControlCenter", Self.ownID])
  func rejectsUnmanagedOrProtectedApplications(id: String) async throws {
    let fixture = try Fixture([
      "example.a": true, "com.apple.ControlCenter": true, Self.ownID: true,
    ])
    defer { fixture.cleanUp() }
    await #expect(throws: MenuBarVisibilityError.self) {
      try await fixture.store.collapse([id], ownBundleID: Self.ownID)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    #expect(try fixture.states().values.allSatisfy { $0 })
  }

  @Test func alreadyHiddenApplicationDoesNotBecomeOwned() async throws {
    let fixture = try Fixture(["example.a": false])
    defer { fixture.cleanUp() }
    try await fixture.store.collapse(["example.a"], ownBundleID: Self.ownID)
    try await fixture.store.restore()
    #expect(try fixture.states()["example.a"] == false)
    #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
  }

  @Test func nativeDefaultsRoundTripPreservesOtherPreferenceKeys() async throws {
    let fixture = try Fixture(["example.a": true, "example.b": false])
    defer { fixture.cleanUp() }
    let directory = fixture.journal.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("preferences.plist")
    let root: [String: Any] = [
      "trackedApplications": try fixture.client.read(), "unrelated": "keep",
    ]
    try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0).write(
      to: file)
    let client = MenuBarVisibilityStore.Client.preferences(at: file)
    let store = MenuBarVisibilityStore(client: client, journal: fixture.journal)
    try await store.collapse(["example.a"], ownBundleID: Self.ownID)
    #expect(try await store.read() == ["example.a": false, "example.b": false])
    try await store.restore()
    #expect(try await store.read() == ["example.a": true, "example.b": false])

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = ["export", file.deletingPathExtension().path, "-"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let exported = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(exported["unrelated"] as? String == "keep")
  }

  @MainActor @Test func disablingRestoresAppsAndPreservesManualChoice() async throws {
    let fixture = try Fixture(["example.a": true])
    defer { fixture.cleanUp() }
    let suite = "MenuBarVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarFoldingEnabled = true
    let folding = MenuBarApplicationFolding(
      settings: settings, store: fixture.store, applicationURLs: fixture.applicationURLs)
    folding.setEnabled(true)
    try await settle(folding)
    folding.select("example.a", enabled: true)
    folding.toggle()
    try await settle(folding)
    #expect(folding.isCollapsed)
    #expect(settings.menuBarFoldingCollapsed)
    settings.menuBarFoldingEnabled = false
    folding.setEnabled(false)
    try await settle(folding)
    #expect(!folding.isCollapsed)
    #expect(settings.menuBarFoldingCollapsed)
    #expect(try fixture.states()["example.a"] == true)
  }

  @MainActor @Test func disabledStartupRecoversEarlierSession() async throws {
    let fixture = try Fixture(["example.a": true])
    defer { fixture.cleanUp() }
    try await fixture.store.collapse(["example.a"], ownBundleID: Self.ownID)
    let suite = "MenuBarVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let folding = MenuBarApplicationFolding(
      settings: AppSettings(defaults: defaults), store: fixture.store,
      applicationURLs: fixture.applicationURLs)
    folding.setEnabled(false)
    try await settle(folding)
    #expect(try fixture.states()["example.a"] == true)
    #expect(!folding.recoveryNeeded)
    #expect(!folding.requiresTerminationPreparation)
  }

  @MainActor @Test func terminationWaitsForPendingCollapseAndRestoresIt() async throws {
    let fixture = try Fixture(["example.a": true])
    defer { fixture.cleanUp() }
    let suite = "MenuBarVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarFoldingEnabled = true
    let folding = MenuBarApplicationFolding(
      settings: settings, store: fixture.store, applicationURLs: fixture.applicationURLs)
    folding.setEnabled(true)
    try await settle(folding)
    folding.select("example.a", enabled: true)
    folding.toggle()
    #expect(folding.requiresTerminationPreparation)
    try await folding.prepareForTermination()
    #expect(try fixture.states()["example.a"] == true)
    #expect(!folding.isCollapsed)
    #expect(!fixture.store.hasRecoveryRecord)
  }

  @MainActor @Test func cancelledTerminationRevalidatesFileAccess() async throws {
    let fixture = try Fixture(["example.a": true])
    defer { fixture.cleanUp() }
    let suite = "MenuBarVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarFoldingEnabled = true
    let folding = MenuBarApplicationFolding(
      settings: settings, store: fixture.store, applicationURLs: fixture.applicationURLs)
    folding.setEnabled(true)
    try await settle(folding)
    folding.select("example.a", enabled: true)
    folding.toggle()
    try await settle(folding)
    try await folding.prepareForTermination()

    // 模拟退出准备之后书签失效；取消退出不能沿用此前读取成功的授权状态。
    defaults.set(Data([0]), forKey: "menuBarFoldingFileBookmark")
    var openedManagement = false
    folding.showManagement = { openedManagement = true }
    folding.cancelTermination()
    #expect(!folding.hasAccess)
    folding.toggle()
    try await settle(folding)
    #expect(openedManagement)
    #expect(!folding.isCollapsed)
    #expect(!fixture.store.hasRecoveryRecord)
    #expect(try fixture.states()["example.a"] == true)
  }

  @MainActor @Test(arguments: [false, true])
  func failedRestorationRequiresExplicitQuitConsent(allowQuit: Bool) async throws {
    let fixture = try Fixture(["example.a": true])
    defer { fixture.cleanUp() }
    let suite = "MenuBarVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarFoldingEnabled = true
    let folding = MenuBarApplicationFolding(
      settings: settings, store: fixture.store, applicationURLs: fixture.applicationURLs)
    folding.setEnabled(true)
    try await settle(folding)
    folding.select("example.a", enabled: true)
    folding.toggle()
    try await settle(folding)
    let journal = try Data(contentsOf: fixture.journal)
    fixture.failReads(.accessDenied)
    var confirmations = 0
    do {
      try await folding.prepareForTermination {
        confirmations += 1
        return allowQuit
      }
      #expect(allowQuit)
    } catch {
      #expect(!allowQuit)
    }
    #expect(confirmations == 1)
    #expect(folding.recoveryNeeded && folding.issue != nil)
    #expect(try Data(contentsOf: fixture.journal) == journal)
    #expect(try fixture.states()["example.a"] == false)

    if allowQuit {
      folding.refresh()
      #expect(!folding.isBusy)
      // 后续网络退出门禁拒绝退出时，仍可取消退出并重新操作。
      folding.cancelTermination()
    }
    fixture.failReads(nil)
    folding.refresh()
    try await settle(folding)
    #expect(try fixture.states()["example.a"] == true)
    #expect(!fixture.store.hasRecoveryRecord)
  }

  @MainActor @Test func quittingWithPendingRecoveryPreservesNextStartupRetry() async throws {
    let fixture = try Fixture(["example.a": true])
    defer { fixture.cleanUp() }
    try await fixture.store.collapse(["example.a"], ownBundleID: Self.ownID)
    let suite = "MenuBarVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let folding = MenuBarApplicationFolding(
      settings: settings, store: fixture.store, applicationURLs: fixture.applicationURLs)
    fixture.failReads(.invalidFormat)
    try await folding.prepareForTermination { true }
    #expect(fixture.store.hasRecoveryRecord)
    #expect(try fixture.states()["example.a"] == false)
    fixture.failReads(nil)
    let restarted = MenuBarApplicationFolding(
      settings: settings,
      store: MenuBarVisibilityStore(client: fixture.client, journal: fixture.journal),
      applicationURLs: fixture.applicationURLs)
    restarted.setEnabled(false)
    try await settle(restarted)
    #expect(try fixture.states()["example.a"] == true)
    #expect(!fixture.store.hasRecoveryRecord)
  }

  @MainActor @Test func corruptedRecoveryRecordAllowsExplicitQuitWithoutDiscardingIt() async throws
  {
    let fixture = try Fixture(["example.a": true])
    defer { fixture.cleanUp() }
    try await fixture.store.collapse(["example.a"], ownBundleID: Self.ownID)
    let corrupt = Data("invalid recovery record".utf8)
    try corrupt.write(to: fixture.journal)
    let suite = "MenuBarVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let folding = MenuBarApplicationFolding(
      settings: AppSettings(defaults: defaults), store: fixture.store,
      applicationURLs: fixture.applicationURLs)
    await #expect(throws: (any Error).self) { try await folding.prepareForTermination() }
    try await folding.prepareForTermination { true }
    #expect(try Data(contentsOf: fixture.journal) == corrupt)
    #expect(try fixture.states()["example.a"] == false)
  }

  @MainActor @Test func listOnlyIncludesExistingTrackedApplications() async throws {
    let states = [
      "example.installed": true, "example.missing": true, "example.unresolved": true,
      "example.trash": true, "example.wrong": true, "example.fallback": true,
      "com.apple.Finder": true, Self.ownID: true, Self.ownID + ".helper": true,
    ]
    let fixture = try Fixture(states)
    defer { fixture.cleanUp() }
    try fixture.install("example.noLongerTracked")
    let suite = "MenuBarVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
      ["example.installed", "example.missing", "example.noLongerTracked", "com.apple.Finder"],
      forKey: "menuBarFoldingApplications")
    let missing = fixture.applicationURL("example.missing")
    try FileManager.default.removeItem(at: missing)
    let trash = fixture.journal.deletingLastPathComponent().appendingPathComponent(".Trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let trashedApp = trash.appendingPathComponent("Removed.app")
    try FileManager.default.moveItem(at: fixture.applicationURL("example.trash"), to: trashedApp)
    let folding = MenuBarApplicationFolding(
      settings: AppSettings(defaults: defaults), store: fixture.store,
      applicationURLs: { id in
        switch id {
        case "example.unresolved": []
        case "example.trash": [trashedApp]
        case "example.wrong": [fixture.applicationURL("example.installed")]
        case "example.fallback": [missing, fixture.applicationURL(id)]
        default: fixture.applicationURLs(id)
        }
      })
    folding.refresh()
    try await settle(folding)
    #expect(Set(folding.applications.map(\.id)) == ["example.installed", "example.fallback"])
    #expect(folding.selected == ["example.installed"])
    #expect(defaults.stringArray(forKey: "menuBarFoldingApplications") == ["example.installed"])
    #expect(try fixture.states() == states)
  }

  @MainActor @Test(arguments: [false, true])
  func uninstallAfterLoadingDoesNotBlockRemainingApplications(removeAll: Bool) async throws {
    let fixture = try Fixture(["example.a": true, "example.b": true])
    defer { fixture.cleanUp() }
    let suite = "MenuBarVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarFoldingEnabled = true
    let folding = MenuBarApplicationFolding(
      settings: settings, store: fixture.store, applicationURLs: fixture.applicationURLs)
    folding.setEnabled(true)
    try await settle(folding)
    folding.select("example.a", enabled: true)
    folding.select("example.b", enabled: true)
    try FileManager.default.removeItem(at: fixture.applicationURL("example.a"))
    if removeAll { try FileManager.default.removeItem(at: fixture.applicationURL("example.b")) }
    var openedManagement = false
    folding.showManagement = { openedManagement = true }
    folding.toggle()
    try await settle(folding)
    #expect(folding.selected == (removeAll ? [] : ["example.b"]))
    #expect(folding.isCollapsed == !removeAll)
    #expect(openedManagement == removeAll)
    #expect(try fixture.states() == ["example.a": true, "example.b": removeAll])
    folding.expand()
    try await settle(folding)
    #expect(try fixture.states() == ["example.a": true, "example.b": true])
    #expect(!fixture.store.hasRecoveryRecord)
  }

  @MainActor @Test func inactiveBuildProductsAreNotInstalledApplications() async throws {
    let states = ["example.inactive": true, "example.running": true, "example.installed": true]
    let fixture = try Fixture(states)
    defer { fixture.cleanUp() }
    let products = fixture.journal.deletingLastPathComponent()
      .appendingPathComponent("DerivedData/Example/Build/Products/Debug")
    try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
    for id in states.keys {
      try FileManager.default.moveItem(
        at: fixture.applicationURL(id), to: products.appendingPathComponent("\(id).app"))
    }
    // 同一标识符同时有旧编译产物和正式副本时，仍须找到后者。
    try fixture.install("example.installed")
    let suite = "MenuBarVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(states.keys.sorted(), forKey: "menuBarFoldingApplications")
    let folding = MenuBarApplicationFolding(
      settings: AppSettings(defaults: defaults), store: fixture.store,
      applicationURLs: { id in
        [products.appendingPathComponent("\(id).app"), fixture.applicationURL(id)]
      },
      runningApplicationURLs: { id in
        id == "example.running" ? [products.appendingPathComponent("\(id).app")] : []
      })
    folding.refresh()
    try await settle(folding)
    #expect(Set(folding.applications.map(\.id)) == ["example.running", "example.installed"])
    #expect(folding.selected == ["example.running", "example.installed"])
    #expect(try fixture.states() == states)
  }

  @MainActor @Test func restoresJournalBeforeRemovingUninstalledSelection() async throws {
    let fixture = try Fixture(["example.a": true])
    defer { fixture.cleanUp() }
    try await fixture.store.collapse(["example.a"], ownBundleID: Self.ownID)
    try FileManager.default.removeItem(at: fixture.applicationURL("example.a"))
    let suite = "MenuBarVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["example.a"], forKey: "menuBarFoldingApplications")
    let settings = AppSettings(defaults: defaults)
    settings.menuBarFoldingEnabled = true
    settings.menuBarFoldingCollapsed = true
    let folding = MenuBarApplicationFolding(
      settings: settings, store: fixture.store, applicationURLs: fixture.applicationURLs)
    folding.setEnabled(true)
    try await settle(folding)
    #expect(folding.applications.isEmpty && folding.selected.isEmpty)
    #expect(!folding.isCollapsed && !folding.recoveryNeeded)
    #expect(try fixture.states()["example.a"] == true)
    #expect(!fixture.store.hasRecoveryRecord)
  }

  @MainActor private func settle(_ folding: MenuBarApplicationFolding) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while folding.isBusy && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(!folding.isBusy)
    try #require(folding.issue == nil)
  }

  /// 夹具通过锁保护所有可变内容；模拟系统偏好服务，而不访问开发机真实配置。
  private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data
    private var failsAfterWrite = false
    private var readFailure: MenuBarVisibilityError?
    let journal = FileManager.default.temporaryDirectory
      .appendingPathComponent("MenuBarVisibilityTests-\(UUID())/recovery.json")

    init(_ states: [String: Bool]) throws {
      let rows: [Any] = states.sorted(by: { $0.key < $1.key }).flatMap { id, allowed in
        [["bundle": ["_0": id]] as [String: Any], ["isAllowed": allowed]]
      }
      data = try PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0)
      for id in states.keys { try install(id) }
    }

    func install(_ id: String) throws {
      let contents = applicationURL(id).appendingPathComponent("Contents")
      try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
      try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"],
        format: .xml, options: 0
      ).write(to: contents.appendingPathComponent("Info.plist"))
    }

    func applicationURL(_ id: String) -> URL {
      journal.deletingLastPathComponent().appendingPathComponent("\(id).app")
    }

    func applicationURLs(_ id: String) -> [URL] { [applicationURL(id)] }

    var client: MenuBarVisibilityStore.Client {
      .init(
        read: {
          try self.lock.withLock {
            if let error = self.readFailure { throw error }
            return self.data
          }
        },
        write: { data in
          try self.lock.withLock {
            self.data = data
            if self.failsAfterWrite {
              self.failsAfterWrite = false
              throw MenuBarVisibilityError.processFailed
            }
          }
        })
    }
    lazy var store = MenuBarVisibilityStore(client: client, journal: journal)

    func states() throws -> [String: Bool] {
      try lock.withLock { try MenuBarApplicationList(data: data).states }
    }
    func set(_ id: String, allowed: Bool) throws {
      try lock.withLock { data = try MenuBarApplicationList(data: data).updating([id: allowed]) }
    }
    func failAfterNextWrite() { lock.withLock { failsAfterWrite = true } }
    func failReads(_ error: MenuBarVisibilityError?) { lock.withLock { readFailure = error } }
    func cleanUp() { try? FileManager.default.removeItem(at: journal.deletingLastPathComponent()) }
  }
}
