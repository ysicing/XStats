// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Darwin
import Testing
@testable import Cleaner
@testable import XStatsUI

@Suite(.serialized)
@MainActor struct AppManagementControllerTests {
  private func app(_ name: String) -> InstalledApp {
    InstalledApp(
      url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name,
      bundleIdentifier: "test.\(name)", version: "1", teamIdentifier: nil)
  }

  private func waitFor(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(120)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }

  @Test func storeChecksReuseResultsAndManualFailuresStaySilent() async throws {
    let fixture = app("Store")
    let calls = AppManagementTestValue(0)
    let date = AppManagementTestValue(Date())
    let controller = AppManagementController(
      listApps: { [fixture] },
      inspectApp: { _ in
        ApplicationMetadata(isAppStore: true, appStoreID: "123")
      }, measureSize: { _ in 1 }, brewAvailable: false,
      checkStore: { _, _ in
        let count = calls.withLock {
          $0 += 1
          return $0
        }
        if count > 1 { throw URLError(.notConnectedToInternet) }
        return .init(entries: [
          fixture.bundleIdentifier: .init(
            bundleIdentifier: fixture.bundleIdentifier,
            version: "2", minimumSystemVersion: "14", storeID: "123")
        ])
      }, now: { date.withLock { $0 } })
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { !controller.isReading && !controller.isCheckingAppStore }
    #expect(controller.appStoreUpdates[fixture.id]?.version == "2")
    for _ in 0..<5 {
      controller.setVisible(false)
      controller.setVisible(true)
      try await waitFor { !controller.isReading && !controller.isCheckingAppStore }
    }
    #expect(calls.withLock { $0 } == 1)
    controller.checkAppStoreUpdates(force: true)
    try await waitFor { !controller.isCheckingAppStore }
    #expect(controller.error == nil && controller.appStoreUpdates.isEmpty)
    controller.setVisible(false)
    controller.setVisible(true)
    try await waitFor { !controller.isReading && !controller.isCheckingAppStore }
    #expect(calls.withLock { $0 } == 2)
    date.withLock { $0 += AppManagementController.storeMissingRetryDelay + 1 }
    controller.setVisible(true)
    try await waitFor { !controller.isReading && !controller.isCheckingAppStore }
    #expect(calls.withLock { $0 } == 3)
  }

  @Test func storeHandoffOpensOnlyTheStoreAndRechecksInstalledVersion() async throws {
    let fixture = app("Store")
    let updated = InstalledApp(
      url: fixture.url, name: fixture.name, bundleIdentifier: fixture.bundleIdentifier,
      version: "2", teamIdentifier: nil)
    let inventory = AppManagementTestValue([fixture])
    let urls = AppManagementTestValue([URL]())
    let controller = AppManagementController(
      listApps: { inventory.withLock { $0 } },
      inspectApp: { _ in
        ApplicationMetadata(isAppStore: true, appStoreID: "123")
      }, measureSize: { _ in 1 }, brewAvailable: false,
      checkStore: { _, _ in
        .init(entries: [
          fixture.bundleIdentifier: .init(
            bundleIdentifier: fixture.bundleIdentifier,
            version: "2", minimumSystemVersion: "14", storeID: "123")
        ])
      },
      openStore: { url in
        urls.withLock { $0.append(url) }
        return true
      })
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { !controller.isReading && !controller.isCheckingAppStore }
    controller.openAppStoreUpdate(for: fixture)
    #expect(
      urls.withLock { $0.map(\.absoluteString) } == ["macappstore://itunes.apple.com/app/id123"])
    controller.setVisible(false)
    inventory.withLock { $0 = [updated] }
    controller.setVisible(true)
    try await waitFor { !controller.isReading && !controller.isCheckingAppStore }
    #expect(controller.apps.first?.version == "2" && controller.appStoreUpdates.isEmpty)
    controller.openAppStoreUpdate(for: fixture)
    #expect(urls.withLock { $0.count } == 1)
  }

  @Test func storeLookupRejectsLateResultsAfterClosing() async throws {
    let fixture = app("Store")
    let gate = StoreLookupGate()
    let controller = AppManagementController(
      listApps: { [fixture] },
      inspectApp: { _ in
        ApplicationMetadata(isAppStore: true)
      }, measureSize: { _ in 1 }, brewAvailable: false,
      checkStore: { _, _ in
        await gate.wait()
        return .init(entries: [
          fixture.bundleIdentifier: .init(
            bundleIdentifier: fixture.bundleIdentifier,
            version: "2", minimumSystemVersion: "14", storeID: "123")
        ])
      })
    controller.setVisible(true)
    try await waitFor { controller.isCheckingAppStore }
    controller.setVisible(false)
    #expect(controller.isCheckingAppStore == false)
    await gate.release()
    await Task.yield()
    #expect(controller.appStoreUpdates.isEmpty && controller.error == nil)
    controller.setEnabled(false)
    #expect(controller.appStoreUpdates.isEmpty)
  }

  @Test func rapidReopeningReusesInventoryAndMetadataButExpiryRefreshesLastOpened() async throws {
    let fixture = app("Editor")
    let date = AppManagementTestValue(Date())
    let calls = AppManagementTestValue((lists: 0, metadata: 0, sizes: 0))
    let controller = AppManagementController(
      listApps: {
        calls.withLock { $0.lists += 1 }
        return [fixture]
      },
      inspectApp: { _ in
        calls.withLock { $0.metadata += 1 }
        return ApplicationMetadata(lastOpened: date.withLock { $0 })
      },
      measureSize: { _ in
        calls.withLock { $0.sizes += 1 }
        return 42
      }, brewAvailable: false,
      now: { date.withLock { $0 } })
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { !controller.isReading }
    let originalDate = controller.metadata[fixture.id]?.lastOpened
    for _ in 0..<10 {
      controller.setVisible(false)
      controller.setVisible(true)
      controller.selectTab(.homebrew)
      controller.selectTab(.apps)
      try await waitFor { !controller.isReading }
    }
    #expect(calls.withLock { $0.lists == 1 && $0.metadata == 1 && $0.sizes == 1 })
    date.withLock { $0 += AppManagementController.appInventoryLifetime + 1 }
    controller.setVisible(true)
    try await waitFor { !controller.isReading }
    #expect(calls.withLock { $0.lists == 2 && $0.metadata == 1 && $0.sizes == 1 })
    date.withLock { $0 += AppManagementController.appMetadataLifetime }
    controller.setVisible(true)
    try await waitFor { !controller.isReading }
    #expect(calls.withLock { $0.lists == 3 && $0.metadata == 2 && $0.sizes == 1 })
    #expect(controller.metadata[fixture.id]?.lastOpened != originalDate)
    controller.refresh()
    try await waitFor { !controller.isReading }
    #expect(calls.withLock { $0.lists == 4 && $0.metadata == 3 && $0.sizes == 2 })
  }

  @Test func knownInventoryChangesBypassLifetimeAndOnlyInvalidateChangedMetadata() async throws {
    let old = app("Editor")
    let other = app("Other")
    let updated = InstalledApp(
      url: old.url, name: old.name, bundleIdentifier: old.bundleIdentifier, version: "2",
      teamIdentifier: nil)
    let entries = AppManagementTestValue([old, other])
    let inspected = AppManagementTestValue([String]())
    let controller = AppManagementController(
      listApps: { entries.withLock { $0 } },
      inspectApp: { app in
        inspected.withLock { $0.append(app.id) }
        return ApplicationMetadata(architecture: app.version == "2" ? .appleSilicon : .intel)
      }, measureSize: { _ in 42 }, brewAvailable: false)
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { !controller.isReading }
    inspected.withLock { $0 = [] }
    entries.withLock { $0 = [updated, other] }
    controller.reloadInventory()
    try await waitFor { !controller.isReading }
    #expect(inspected.withLock { $0 } == [old.id])
    #expect(controller.metadata[old.id]?.architecture == .appleSilicon)
    entries.withLock { $0 = [other] }
    controller.reloadInventory()
    try await waitFor { !controller.isReading }
    #expect(
      controller.apps == [other] && controller.metadata[old.id] == nil
        && controller.sizes[old.id] == nil)
  }

  @Test(arguments: [false, true])
  func knownInventoryChangesWhileHiddenOrPausedRefreshOnResume(_ paused: Bool) async throws {
    let removed = app("Removed")
    let retained = app("Retained")
    let entries = AppManagementTestValue([removed, retained])
    let calls = AppManagementTestValue((lists: 0, metadata: 0, sizes: 0))
    let date = Date()
    let controller = AppManagementController(
      listApps: {
        calls.withLock { $0.lists += 1 }
        return entries.withLock { $0 }
      },
      inspectApp: { _ in
        calls.withLock { $0.metadata += 1 }
        return ApplicationMetadata()
      },
      measureSize: { _ in
        calls.withLock { $0.sizes += 1 }
        return 42
      },
      brewAvailable: false, now: { date })
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { !controller.isReading }

    if paused { controller.setPaused(true) } else { controller.setVisible(false) }
    entries.withLock { $0 = [retained] }
    controller.reloadInventory()
    #expect(!controller.isReading)
    #expect(calls.withLock { $0.lists == 1 && $0.metadata == 2 && $0.sizes == 2 })

    if paused { controller.setPaused(false) } else { controller.setVisible(true) }
    try await waitFor { !controller.isReading }
    #expect(controller.apps == [retained])
    #expect(controller.metadata[removed.id] == nil && controller.sizes[removed.id] == nil)
    #expect(calls.withLock { $0.lists == 2 && $0.metadata == 2 && $0.sizes == 2 })
  }

  @Test func iconCacheEvictsOneColdEntryAndKeepsRecentlyUsedIcons() throws {
    var loads = 0
    let icon = try #require(NSImage(systemSymbolName: "app", accessibilityDescription: nil))
    let cache = AppIconCache(loadIcon: { _ in
      loads += 1
      return icon
    })
    for index in 0..<128 { _ = cache.image(bundlePath: "/test/\(index).app") }
    #expect(loads == 128)
    _ = cache.image(bundlePath: "/test/0.app")
    _ = cache.image(bundlePath: "/test/128.app")
    _ = cache.image(bundlePath: "/test/0.app")
    _ = cache.image(bundlePath: "/test/127.app")
    #expect(loads == 129)
    _ = cache.image(bundlePath: "/test/1.app")
    #expect(loads == 130)
  }

  @Test func sizeBatchesPublishProgressAndRejectCancelledBatch() async throws {
    let fixtures = (0..<45).map { app("App\($0)") }
    let calls = AppManagementTestValue(0)
    let blocked = AppManagementTestValue(false)
    let controller = AppManagementController(
      listApps: { fixtures }, inspectApp: { _ in ApplicationMetadata() },
      measureSize: { _ in
        let number = calls.withLock {
          $0 += 1
          return $0
        }
        if number == 21 {
          blocked.withLock { $0 = true }
          while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
          throw CancellationError()
        }
        return 42
      }, brewAvailable: false)
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { blocked.withLock { $0 } }
    #expect(controller.sizes.count == 20)
    controller.setVisible(false)
    controller.setVisible(true)
    try await waitFor { !controller.isReading }
    #expect(controller.sizes.count == 45)
    #expect(calls.withLock { $0 } == 46)
  }

  @Test func restartingShowsCachedRowsBeforeTheLiveReadAndReusesUnchangedSizes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("inventory.json")
    let fixture = app("Editor")
    let first = AppManagementController(
      listApps: { [fixture] }, inspectApp: { _ in ApplicationMetadata(architecture: .universal) },
      measureSize: { _ in 42 }, brewAvailable: false, cacheURL: url)
    first.setVisible(true)
    try await waitFor { !first.isReading && first.sizes[fixture.id] == 42 }
    first.setVisible(false)
    let entered = AppManagementTestValue(false)
    let release = AppManagementTestValue(false)
    let measurements = AppManagementTestValue(0)
    let restarted = AppManagementController(
      listApps: {
        entered.withLock { $0 = true }
        while !release.withLock({ $0 }), !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        return [fixture]
      }, inspectApp: { _ in ApplicationMetadata(architecture: .universal) },
      measureSize: { _ in
        measurements.withLock { $0 += 1 }
        return 99
      }, brewAvailable: false, cacheURL: url)
    defer {
      release.withLock { $0 = true }
      restarted.setVisible(false)
    }
    #expect(restarted.apps.isEmpty && !entered.withLock { $0 })
    restarted.setVisible(true)
    try await waitFor { entered.withLock { $0 } }
    #expect(restarted.apps == [fixture] && restarted.sizes[fixture.id] == 42)
    #expect(restarted.metadata[fixture.id]?.architecture == .universal)
    #expect(!restarted.isLoadingApps && !restarted.isRefreshingApps)
    release.withLock { $0 = true }
    try await waitFor { !restarted.isReading }
    #expect(measurements.withLock { $0 } == 0)
    restarted.setVisible(false)
    restarted.setVisible(true)
    #expect(restarted.apps == [fixture] && !restarted.isLoadingApps && !restarted.isRefreshingApps)
    try await waitFor { !restarted.isReading }
    #expect(measurements.withLock { $0 } == 0)
  }

  @Test func liveInventoryRemovesDeletedRowsAndRemeasuresUpdatedAndAddedApps() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("inventory.json")
    let old = app("Editor")
    let removed = app("Removed")
    let added = app("New")
    let updated = InstalledApp(
      url: old.url, name: old.name, bundleIdentifier: old.bundleIdentifier, version: "2",
      teamIdentifier: nil)
    try AppInventoryCache(
      entries: [old, removed].map {
        AppInventoryCache.Entry(
          app: $0, metadata: ApplicationMetadata(), size: 42, measuredAt: Date(),
          fingerprint: .read($0))
      }
    ).save(to: url)
    let measured = AppManagementTestValue(Set<String>())
    let controller = AppManagementController(
      listApps: { [updated, added] }, inspectApp: { _ in ApplicationMetadata() },
      measureSize: { url in
        _ = measured.withLock { $0.insert(url.path) }
        return 99
      }, brewAvailable: false, cacheURL: url)
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { !controller.isReading }
    #expect(controller.apps == [updated, added])
    #expect(controller.sizes[removed.id] == nil && controller.metadata[removed.id] == nil)
    #expect(measured.withLock { $0 } == Set([updated.id, added.id]))
    #expect(controller.sizes[updated.id] == 99 && controller.sizes[added.id] == 99)
    #expect(try AppInventoryCache.load(from: url)?.entries.map(\.app) == [updated, added])
  }

  @Test func changedFingerprintsAndExpiredMeasurementsAreNotReused() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("inventory.json")
    let changed = app("Changed")
    let expired = app("Expired")
    try AppInventoryCache(entries: [
      .init(
        app: changed, metadata: ApplicationMetadata(), size: 42, measuredAt: Date(),
        fingerprint: .init(bundleModified: .distantPast, infoModified: nil)),
      .init(
        app: expired, metadata: ApplicationMetadata(), size: 42,
        measuredAt: Date().addingTimeInterval(-172_800),
        fingerprint: .read(expired)),
    ]).save(to: url)
    let measured = AppManagementTestValue(Set<String>())
    let controller = AppManagementController(
      listApps: { [changed, expired] }, inspectApp: { _ in ApplicationMetadata() },
      measureSize: { url in
        _ = measured.withLock { $0.insert(url.path) }
        return 99
      }, brewAvailable: false, cacheURL: url)
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { !controller.isReading }
    #expect(measured.withLock { $0 } == Set([changed.id, expired.id]))
  }

  @Test func corruptCacheFallsBackToLiveInventory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("inventory.json")
    try Data("invalid json".utf8).write(to: url)
    let fixture = app("Editor")
    let controller = AppManagementController(
      listApps: { [fixture] }, inspectApp: { _ in ApplicationMetadata() },
      measureSize: { _ in 42 }, brewAvailable: false, cacheURL: url)
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { !controller.isReading }
    #expect(
      controller.apps == [fixture] && controller.sizes[fixture.id] == 42 && controller.error == nil)
    #expect(try AppInventoryCache.load(from: url)?.entries.count == 1)
  }

  @Test func cacheWriteFailureDoesNotBlockBrowsingAndCanRecover() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let parent = directory.appendingPathComponent("blocked")
    try Data([1]).write(to: parent)
    let url = parent.appendingPathComponent("inventory.json")
    let fixture = app("Editor")
    let controller = AppManagementController(
      listApps: { [fixture] }, inspectApp: { _ in ApplicationMetadata() },
      measureSize: { _ in 42 }, brewAvailable: false, cacheURL: url)
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { !controller.isReading }
    controller.refresh()
    try await waitFor { !controller.isReading }
    #expect(
      controller.apps == [fixture] && controller.sizes[fixture.id] == 42 && controller.error == nil)
    try FileManager.default.removeItem(at: parent)
    controller.refresh()
    try await waitFor { !controller.isReading }
    #expect(try AppInventoryCache.load(from: url)?.entries.first?.size == 42)
    #expect(controller.error == nil)
  }

  @Test func closingACachedPageCancelsRefreshAndKeepsOnlyTheDisplayedSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("inventory.json")
    let fixture = app("Editor")
    try AppInventoryCache(entries: [
      .init(
        app: fixture, metadata: ApplicationMetadata(), size: 42, measuredAt: Date(),
        fingerprint: .read(fixture))
    ]).save(to: url)
    let entered = AppManagementTestValue(false)
    let finished = AppManagementTestValue(false)
    let controller = AppManagementController(
      listApps: {
        entered.withLock { $0 = true }
        defer { finished.withLock { $0 = true } }
        while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        return []
      }, brewAvailable: false, cacheURL: url)
    controller.setVisible(true)
    try await waitFor { entered.withLock { $0 } }
    controller.setVisible(false)
    try await waitFor { finished.withLock { $0 } }
    #expect(!controller.isReading && !controller.isRefreshingApps && controller.apps == [fixture])
    #expect(try AppInventoryCache.load(from: url)?.entries.map(\.app) == [fixture])
  }

  @Test func cacheRejectsExpiredDuplicateAndOversizedSnapshots() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("inventory.json")
    let entry = AppInventoryCache.Entry(
      app: app("Editor"), metadata: nil, size: nil, measuredAt: nil, fingerprint: nil)
    try AppInventoryCache(
      entries: [entry], savedAt: Date().addingTimeInterval(-AppInventoryCache.lifetime - 60)
    ).save(to: url)
    #expect(try AppInventoryCache.load(from: url) == nil)
    try AppInventoryCache(entries: [entry, entry]).save(to: url)
    #expect(try AppInventoryCache.load(from: url) == nil)
    try Data(repeating: 0, count: AppInventoryCache.maximumBytes + 1).write(to: url)
    #expect(try AppInventoryCache.load(from: url) == nil)
  }

  @Test func cachedHomebrewSourceNeverAuthorizesAnUninstallBeforeTheLiveInventory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("inventory.json")
    let fixture = app("Editor")
    try AppInventoryCache(entries: [
      .init(
        app: fixture, metadata: ApplicationMetadata(), size: 42, measuredAt: Date(),
        fingerprint: .read(fixture), isHomebrew: true)
    ]).save(to: url)
    let package = HomebrewPackage(
      name: "editor", displayName: "Editor", kind: .cask, installedVersions: ["1"],
      latestVersion: nil,
      outdated: false, pinned: false, installationURLs: [fixture.url],
      applicationURLs: [fixture.url])
    let entered = AppManagementTestValue(false)
    let release = AppManagementTestValue(false)
    let writes = AppManagementTestValue(0)
    let controller = AppManagementController(
      listApps: { [fixture] }, inspectApp: { _ in ApplicationMetadata() }, brewAvailable: true,
      listPackages: {
        entered.withLock { $0 = true }
        while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        return []
      }, performAction: { _, _ in writes.withLock { $0 += 1 } }, cacheURL: url)
    defer {
      release.withLock { $0 = true }
      controller.setVisible(false)
    }
    controller.setVisible(true)
    try await waitFor { controller.apps.count == 1 && entered.withLock { $0 } }
    #expect(controller.homebrewAppPaths.contains(fixture.id))
    #expect(!controller.hasBrewInventory && controller.casksByPath.isEmpty)
    controller.perform(.uninstall, package: package)
    #expect(controller.operation == nil && writes.withLock { $0 } == 0)
    release.withLock { $0 = true }
    try await waitFor { !controller.isReading }
    #expect(controller.hasBrewInventory && controller.homebrewAppPaths.isEmpty)
    #expect(try AppInventoryCache.load(from: url)?.entries.first?.isHomebrew == false)
  }

  @Test func closedAndDisabledPagesNeverReadAndReopeningUsesCompletedSizes() async throws {
    let calls = AppManagementTestValue((list: 0, sizes: 0))
    let fixture = app("Editor")
    let controller = AppManagementController(
      listApps: {
        calls.withLock { $0.list += 1 }
        return [fixture]
      }, inspectApp: { _ in ApplicationMetadata() },
      measureSize: { _ in
        calls.withLock { $0.sizes += 1 }
        return 42
      }, brewAvailable: false)
    try await Task.sleep(for: .milliseconds(50))
    #expect(calls.withLock { $0.list } == 0)
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { controller.sizes[fixture.id] == 42 }
    controller.setVisible(false)
    controller.setVisible(true)
    try await waitFor { !controller.isReading }
    #expect(calls.withLock { $0.list == 1 && $0.sizes == 1 })
    controller.setEnabled(false)
    controller.setVisible(true)
    #expect(!controller.visible && controller.apps.isEmpty)
  }

  @Test func cancellingSizeTraversalRejectsLateResults() async throws {
    let entered = AppManagementTestValue(false)
    let finished = AppManagementTestValue(false)
    let fixture = app("Slow")
    let controller = AppManagementController(
      listApps: { [fixture] }, inspectApp: { _ in ApplicationMetadata() },
      measureSize: { _ in
        entered.withLock { $0 = true }
        defer { finished.withLock { $0 = true } }
        while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        return 99
      }, brewAvailable: false)
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { entered.withLock { $0 } }
    controller.setVisible(false)
    try await waitFor { finished.withLock { $0 } }
    #expect(controller.sizes[fixture.id] == nil)
    #expect(!controller.isLoadingApps)
  }

  @Test func slowSizeTraversalDoesNotDelayOtherApplicationMetadata() async throws {
    let fixtures = [app("Large"), app("Small")]
    let entered = AppManagementTestValue(false)
    let release = AppManagementTestValue(false)
    let controller = AppManagementController(
      listApps: { fixtures },
      inspectApp: { _ in
        ApplicationMetadata(architecture: .appleSilicon)
      },
      measureSize: { _ in
        entered.withLock { $0 = true }
        while !release.withLock({ $0 }), !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        return 42
      }, brewAvailable: false)
    defer {
      release.withLock { $0 = true }
      controller.setVisible(false)
    }
    controller.setVisible(true)
    try await waitFor { entered.withLock { $0 } }
    #expect(controller.apps == fixtures)
    #expect(fixtures.allSatisfy { controller.metadata[$0.id]?.architecture == .appleSilicon })
    #expect(!controller.isLoadingApps)
  }

  @Test func refreshingKeepsMeasuredSizesUntilTheirReplacementsArrive() async throws {
    let fixture = app("Editor")
    let calls = AppManagementTestValue(0)
    let entered = AppManagementTestValue(false)
    let release = AppManagementTestValue(false)
    let controller = AppManagementController(
      listApps: { [fixture] },
      inspectApp: { _ in
        ApplicationMetadata(architecture: .appleSilicon)
      },
      measureSize: { _ in
        let attempt = calls.withLock {
          $0 += 1
          return $0
        }
        if attempt == 1 { return 42 }
        entered.withLock { $0 = true }
        while !release.withLock({ $0 }), !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        return 99
      }, brewAvailable: false)
    defer {
      release.withLock { $0 = true }
      controller.setVisible(false)
    }
    controller.setVisible(true)
    try await waitFor { !controller.isReading && controller.sizes[fixture.id] == 42 }
    controller.refresh()
    try await waitFor { entered.withLock { $0 } }
    #expect(controller.apps == [fixture])
    #expect(controller.sizes[fixture.id] == 42)
    release.withLock { $0 = true }
    try await waitFor { !controller.isReading }
    #expect(controller.sizes[fixture.id] == 99)
  }

  @Test func failedRefreshDoesNotLeaveAnOldSizeAsACurrentMeasurement() async throws {
    let fixture = app("Editor")
    let calls = AppManagementTestValue(0)
    let controller = AppManagementController(
      listApps: { [fixture] }, inspectApp: { _ in ApplicationMetadata() },
      measureSize: { _ in
        let attempt = calls.withLock {
          $0 += 1
          return $0
        }
        if attempt == 1 { return 42 }
        throw CocoaError(.fileReadNoPermission)
      }, brewAvailable: false)
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { !controller.isReading && controller.sizes[fixture.id] == 42 }
    controller.refresh()
    try await waitFor { !controller.isReading }
    #expect(controller.apps == [fixture])
    #expect(controller.sizes[fixture.id] == nil)
    #expect(controller.error == nil && !controller.isMeasuringApps)
  }

  @Test func closingDuringMetadataReadRejectsResultsAndNeverStartsMeasuring() async throws {
    let fixture = app("Editor")
    let entered = AppManagementTestValue(false)
    let finished = AppManagementTestValue(false)
    let measured = AppManagementTestValue(0)
    let controller = AppManagementController(
      listApps: { [fixture] },
      inspectApp: { _ in
        entered.withLock { $0 = true }
        defer { finished.withLock { $0 = true } }
        while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        return ApplicationMetadata(architecture: .appleSilicon)
      },
      measureSize: { _ in
        measured.withLock { $0 += 1 }
        return 42
      }, brewAvailable: false)
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { entered.withLock { $0 } }
    controller.setVisible(false)
    try await waitFor { finished.withLock { $0 } }
    #expect(controller.metadata.isEmpty && controller.sizes.isEmpty)
    #expect(measured.withLock { $0 } == 0)
    #expect(!controller.isLoadingApps && !controller.isMeasuringApps)
  }

  @Test func partialSizesDoNotDiscardOtherPackagesOrTriggerRepeatedWork() async throws {
    let fixture = app("Unreadable")
    let attempts = AppManagementTestValue(0)
    let controller = AppManagementController(
      listApps: { [fixture] }, inspectApp: { _ in ApplicationMetadata(architecture: .intel) },
      measureSize: { _ in
        attempts.withLock { $0 += 1 }
        throw CocoaError(.fileReadNoPermission)
      }, brewAvailable: false)
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { attempts.withLock { $0 } == 1 && !controller.isReading }
    controller.setVisible(false)
    controller.setVisible(true)
    #expect(controller.apps == [fixture] && controller.metadata[fixture.id]?.architecture == .intel)
    #expect(controller.error == nil && controller.sizes.isEmpty)
    try await waitFor { !controller.isReading }
    #expect(attempts.withLock { $0 } == 1)
    controller.setVisible(false)
  }

  @Test func confirmedBrewOperationFinishesAfterPageClosesAndCannotDuplicate() async throws {
    let started = AppManagementTestValue(0)
    let release = AppManagementTestValue(false)
    let package = HomebrewPackage(
      name: "tool", displayName: "tool", kind: .formula, installedVersions: ["1"],
      latestVersion: "2",
      outdated: true, pinned: false, installationURLs: [], applicationURLs: [])
    let controller = AppManagementController(
      listApps: { [] }, brewAvailable: true, listPackages: { [package] },
      performAction: { _, _ in
        started.withLock { $0 += 1 }
        while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
      })
    defer {
      release.withLock { $0 = true }
      controller.setVisible(false)
    }
    controller.setVisible(true, tab: .homebrew)
    try await waitFor { !controller.packages.isEmpty && !controller.isLoadingBrew }
    controller.perform(.upgrade, package: package)
    controller.perform(.uninstall, package: package)
    controller.setVisible(false)
    try await waitFor { started.withLock { $0 } == 1 }
    #expect(controller.operation == .upgrade)
    release.withLock { $0 = true }
    try await waitFor { controller.operation == nil }
    #expect(controller.completion == nil)
  }

  @Test(arguments: [HomebrewManagement.Action.upgrade, .uninstall])
  func completedBrewFeedbackIdentifiesTheActionAndDoesNotReplay(_ action: HomebrewManagement.Action)
    async throws
  {
    let package = HomebrewPackage(
      name: "tool", displayName: "Example Tool", kind: .formula, installedVersions: ["1"],
      latestVersion: "2",
      outdated: true, pinned: false, installationURLs: [], applicationURLs: [])
    let controller = AppManagementController(
      listApps: { [] }, brewAvailable: true, listPackages: { [package] }, performAction: { _, _ in }
    )
    defer { controller.setVisible(false) }
    controller.setVisible(true, tab: .homebrew)
    try await waitFor { !controller.isReading && controller.hasBrewInventory }
    controller.perform(action, package: package)
    try await waitFor { controller.operation == nil && !controller.isReading }
    let first = try #require(controller.completion)
    #expect(first.action == action && first.packageName == package.displayName)
    controller.perform(action, package: package)
    try await waitFor { controller.operation == nil && !controller.isReading }
    let second = try #require(controller.completion)
    #expect(first.id != second.id)
    controller.dismissCompletion(first.id)
    #expect(controller.completion?.id == second.id)
    controller.dismissCompletion(second.id)
    #expect(controller.completion == nil)
    controller.perform(action, package: package)
    try await waitFor { controller.operation == nil && !controller.isReading }
    #expect(controller.completion != nil)
    controller.selectTab(.apps)
    #expect(controller.completion == nil)
    controller.selectTab(.homebrew)
    controller.setVisible(false)
    controller.setVisible(true)
    #expect(controller.completion == nil)
  }

  @Test func uninstallCompletionUsesSharedFeedbackAndDoesNotReplayAfterLeaving() async throws {
    let fixture = app("Example")
    let controller = AppManagementController(listApps: { [] }, brewAvailable: false)
    defer { controller.setVisible(false) }
    controller.showUninstallCompletion(for: fixture)
    #expect(controller.completion == nil)
    controller.setVisible(true)
    controller.showUninstallCompletion(for: fixture)
    let first = try #require(controller.completion)
    #expect(first.action == .uninstall && first.packageName == fixture.name)
    controller.showUninstallCompletion(for: app("Second"))
    let second = try #require(controller.completion)
    controller.dismissCompletion(first.id)
    #expect(controller.completion?.id == second.id)
    controller.dismissCompletion(second.id)
    #expect(controller.completion == nil)
    controller.setPaused(true)
    controller.showUninstallCompletion(for: fixture)
    #expect(controller.completion == nil)
    controller.setPaused(false)
    controller.showUninstallCompletion(for: fixture)
    #expect(controller.completion != nil)
    controller.setVisible(false)
    controller.showUninstallCompletion(for: fixture)
    controller.setVisible(true)
    #expect(controller.completion == nil)
  }

  @Test func failedBrewOperationWithoutOutputFinishesAndReloadsInventory() async throws {
    let reads = AppManagementTestValue(0)
    let package = HomebrewPackage(
      name: "tool", displayName: "tool", kind: .formula, installedVersions: ["1"],
      latestVersion: "2",
      outdated: true, pinned: false, installationURLs: [], applicationURLs: [])
    let controller = AppManagementController(
      listApps: { [] }, brewAvailable: true,
      listPackages: {
        reads.withLock { $0 += 1 }
        return [package]
      },
      performAction: { _, _ in
        throw ToolExecutionError.failed(tool: "brew", status: 23, output: "")
      })
    defer { controller.setVisible(false) }
    controller.setVisible(true, tab: .homebrew)
    try await waitFor { !controller.isReading && controller.hasBrewInventory }
    controller.perform(.upgrade, package: package)
    try await waitFor { controller.operation == nil && !controller.isReading }
    #expect(
      controller.error != nil && controller.completion == nil && controller.operationPackage == nil)
    #expect(reads.withLock { $0 } == 2)
  }

  @Test(arguments: [false, true])
  func brewMetadataRefreshOnlyRemeasuresWhenTheInstallationChanges(_ reinstalled: Bool) async throws
  {
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    let original = HomebrewPackage(
      name: "tool", displayName: "tool", kind: .formula, installedVersions: ["1"],
      latestVersion: "1",
      outdated: false, pinned: false,
      installationURLs: [URL(fileURLWithPath: "/opt/homebrew/Cellar/tool/1")], applicationURLs: [],
      installedAt: date, summary: "Original description", installReason: .dependency)
    let updated = HomebrewPackage(
      name: "tool", displayName: "tool", kind: .formula, installedVersions: ["1"],
      latestVersion: "2",
      outdated: true, pinned: false, installationURLs: original.installationURLs,
      applicationURLs: [],
      installedAt: reinstalled ? date.addingTimeInterval(100) : date,
      summary: "Updated description", installReason: .requested)
    let entries = AppManagementTestValue([original])
    let measurements = AppManagementTestValue(0)
    let controller = AppManagementController(
      listApps: { [] },
      measureSize: { _ in
        measurements.withLock { $0 += 1 }
        return 42
      }, brewAvailable: true, listPackages: { entries.withLock { $0 } }, updateIndex: {})
    defer { controller.setVisible(false) }
    controller.setVisible(true, tab: .homebrew)
    try await waitFor { !controller.isReading && controller.hasBrewInventory }
    #expect(measurements.withLock { $0 } == 1)
    entries.withLock { $0 = [updated] }
    controller.checkBrewUpdates()
    try await waitFor {
      !controller.isCheckingUpdates && !controller.isReading && controller.packages == [updated]
    }
    #expect(measurements.withLock { $0 } == (reinstalled ? 2 : 1))
    #expect(controller.packageSizes[original.id] == 42)
  }

  @Test func failedInventoryBacksOffAndKeepsPlainUninstallAvailable() async throws {
    let calls = AppManagementTestValue(0)
    let controller = AppManagementController(
      listApps: { [] }, brewAvailable: true,
      listPackages: {
        calls.withLock { $0 += 1 }
        throw ToolExecutionError.failed(tool: "brew", status: 1, output: "")
      })
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { calls.withLock { $0 } == 1 && !controller.isReading }
    #expect(
      controller.brewInventoryFailed && controller.hasBrewInventory
        && controller.casksByPath.isEmpty)
    // 自动恢复与切换标签在退避期内不重跑 brew；用户显式刷新可以绕过。
    controller.setVisible(false)
    controller.setVisible(true)
    controller.selectTab(.homebrew)
    controller.selectTab(.apps)
    try await waitFor { !controller.isReading }
    #expect(calls.withLock { $0 } == 1)
    controller.refresh()
    try await waitFor { calls.withLock { $0 } == 2 && !controller.isReading }
    #expect(controller.brewInventoryFailed)
  }

  @Test func userUpdateCheckSurvivesClosingThePageAndReloadsTheInventory() async throws {
    let release = AppManagementTestValue(false)
    let entered = AppManagementTestValue(false)
    let lists = AppManagementTestValue(0)
    let controller = AppManagementController(
      listApps: { [] }, brewAvailable: true,
      listPackages: {
        lists.withLock { $0 += 1 }
        return []
      },
      updateIndex: {
        entered.withLock { $0 = true }
        while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
      })
    defer {
      release.withLock { $0 = true }
      controller.setVisible(false)
    }
    controller.setVisible(true, tab: .homebrew)
    try await waitFor { lists.withLock { $0 } == 1 && !controller.isReading }
    controller.checkBrewUpdates()
    try await waitFor { entered.withLock { $0 } }
    controller.selectTab(.apps)
    controller.setVisible(false)
    #expect(controller.isCheckingUpdates)
    release.withLock { $0 = true }
    try await waitFor { !controller.isCheckingUpdates }
    #expect(controller.error == nil && lists.withLock { $0 } == 1)
    controller.setVisible(true, tab: .homebrew)
    try await waitFor { lists.withLock { $0 } == 2 && !controller.isReading }
  }

  @Test func finishedBrewOperationOnlyRemeasuresTheAffectedApplication() async throws {
    let cask = app("Editor")
    let other = app("Other")
    let package = HomebrewPackage(
      name: "editor", displayName: "Editor", kind: .cask, installedVersions: ["1"],
      latestVersion: "2",
      outdated: true, pinned: false, installationURLs: [cask.url], applicationURLs: [cask.url])
    let measured = AppManagementTestValue([String]())
    let controller = AppManagementController(
      listApps: { [cask, other] }, inspectApp: { _ in ApplicationMetadata() },
      measureSize: { url in
        measured.withLock { $0.append(url.path) }
        return 42
      },
      brewAvailable: true, listPackages: { [package] }, performAction: { _, _ in })
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor {
      !controller.isReading && controller.sizes.count == 2 && controller.hasBrewInventory
    }
    measured.withLock { $0.removeAll() }
    controller.perform(.upgrade, package: package)
    try await waitFor {
      controller.operation == nil && !controller.isReading && controller.hasBrewInventory
    }
    #expect(measured.withLock { $0 } == [cask.id])
    #expect(controller.sizes[other.id] == 42)
  }

  @Test func finishedOperationRereadsTheInventoryDuringFailureBackoff() async throws {
    let package = HomebrewPackage(
      name: "tool", displayName: "tool", kind: .formula, installedVersions: ["1"],
      latestVersion: "2",
      outdated: true, pinned: false, installationURLs: [], applicationURLs: [])
    let calls = AppManagementTestValue(0)
    let controller = AppManagementController(
      listApps: { [] }, brewAvailable: true,
      listPackages: {
        let call = calls.withLock {
          $0 += 1
          return $0
        }
        if call == 2 { throw ToolExecutionError.failed(tool: "brew", status: 1, output: "") }
        return [package]
      }, performAction: { _, _ in })
    defer { controller.setVisible(false) }
    controller.setVisible(true, tab: .homebrew)
    try await waitFor { calls.withLock { $0 } == 1 && !controller.isReading }
    // 手动刷新失败后进入退避，但已有清单仍可用。
    controller.refresh()
    try await waitFor { calls.withLock { $0 } == 2 && !controller.isReading }
    #expect(!controller.brewInventoryFailed && controller.hasBrewInventory)
    // 操作完成后安装状态已变化，必须立即重读，不能停在没有清单、卸载被禁用的状态。
    controller.perform(.upgrade, package: package)
    try await waitFor {
      controller.operation == nil && calls.withLock { $0 } == 3 && !controller.isReading
    }
    #expect(controller.hasBrewInventory && controller.packages == [package])
  }

  @Test func selfPinnedAndStalePackagesCannotStartAnUpdate() async throws {
    let writes = AppManagementTestValue(0)
    let current = HomebrewPackage(
      name: "current", displayName: "current", kind: .cask, installedVersions: ["1"],
      latestVersion: "2",
      outdated: true, pinned: false, installationURLs: [Bundle.main.bundleURL],
      applicationURLs: [Bundle.main.bundleURL])
    let pinned = HomebrewPackage(
      name: "pinned", displayName: "pinned", kind: .formula, installedVersions: ["1"],
      latestVersion: "2",
      outdated: true, pinned: true, installationURLs: [], applicationURLs: [])
    let stale = HomebrewPackage(
      name: "removed", displayName: "removed", kind: .formula, installedVersions: ["1"],
      latestVersion: "2",
      outdated: true, pinned: false, installationURLs: [], applicationURLs: [])
    let controller = AppManagementController(
      listApps: { [] }, brewAvailable: true,
      listPackages: { [current, pinned] }, performAction: { _, _ in writes.withLock { $0 += 1 } })
    defer { controller.setVisible(false) }
    controller.setVisible(true, tab: .homebrew)
    try await waitFor { !controller.isLoadingBrew && controller.packages.count == 2 }
    controller.perform(.uninstall, package: current)
    controller.perform(.upgrade, package: pinned)
    controller.perform(.upgrade, package: stale)
    #expect(controller.operation == nil && writes.withLock { $0 } == 0)
  }

  @Test func symlinkApplicationMatchesTheResolvedRunningBundle() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let realURL = root.appendingPathComponent("Real.app")
    try FileManager.default.createDirectory(at: realURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appendingPathComponent("Link.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realURL)
    let real = InstalledApp(
      url: realURL, name: "Real", bundleIdentifier: "test.real", version: "1", teamIdentifier: nil)
    let package = HomebrewPackage(
      name: "link", displayName: "Link", kind: .cask, installedVersions: ["1"], latestVersion: nil,
      outdated: false, pinned: false, installationURLs: [link], applicationURLs: [link])
    let controller = AppManagementController(brewAvailable: false)
    controller.showPreview(apps: [real], metadata: [:], sizes: [:], packages: [package])
    #expect(controller.isRunning(link))
    #expect(controller.isRunning(package))
    #expect(!controller.isRunning(root.appendingPathComponent("Missing.app")))
  }

  @Test func runningCaskSymlinkDoesNotStartAndReportsTheBlock() async throws {
    let current = Bundle.main.bundleURL.resolvingSymlinksInPath().path
    let currentIdentifier = Bundle.main.bundleIdentifier
    let running = try #require(
      NSWorkspace.shared.runningApplications.compactMap(\.bundleURL).first { url in
        guard url.resolvingSymlinksInPath().path != current else { return false }
        guard let currentIdentifier, let identifier = Bundle(url: url)?.bundleIdentifier else {
          return true
        }
        return identifier.caseInsensitiveCompare(currentIdentifier) != .orderedSame
      })
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appendingPathComponent("Link.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: running)
    let package = HomebrewPackage(
      name: "link", displayName: "Link", kind: .cask, installedVersions: ["1"], latestVersion: "2",
      outdated: true, pinned: false, installationURLs: [link], applicationURLs: [link])
    let writes = AppManagementTestValue(0)
    let controller = AppManagementController(
      listApps: { [] }, measureSize: { _ in 1 }, brewAvailable: true,
      listPackages: { [package] }, performAction: { _, _ in writes.withLock { $0 += 1 } })
    defer { controller.setVisible(false) }
    controller.setVisible(true, tab: .homebrew)
    try await waitFor { controller.packages == [package] && !controller.isLoadingBrew }
    #expect(controller.isRunning(link))
    controller.perform(.uninstall, package: package)
    controller.perform(.upgrade, package: package)
    #expect(controller.operation == nil && controller.error != nil && writes.withLock { $0 } == 0)
  }

  @Test func applicationSymlinkSizeUsesTheBundleRatherThanTheLink() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let target = root.appendingPathComponent("Real.app")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 1, count: 64 * 1024).write(to: target.appendingPathComponent("Payload"))
    let link = root.appendingPathComponent("Link.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let fixture = InstalledApp(
      url: link, name: "Link", bundleIdentifier: "test.link", version: "1", teamIdentifier: nil)
    let package = HomebrewPackage(
      name: "link", displayName: "Link", kind: .cask, installedVersions: ["1"], latestVersion: nil,
      outdated: false, pinned: false, installationURLs: [link], applicationURLs: [link])
    let expected = try CleanEngine.bundleAllocatedSize(of: link)
    let controller = AppManagementController(
      listApps: { [fixture] }, inspectApp: { _ in ApplicationMetadata() },
      brewAvailable: true, listPackages: { [package] })
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { controller.sizes[fixture.id] == expected && !controller.isReading }
    #expect(expected > 0)
    #expect(try CleanEngine.scanAllocatedSize(of: link) == 0)
    controller.selectTab(.homebrew)
    try await waitFor { controller.packageSizes[package.id] == expected && !controller.isReading }
  }

  /// 可选实机检查：只读真实清单，关闭页面后等待目录遍历退出，确认不再发起后台读取。
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["XSTATS_APP_CACHE_RESOURCE_REPORT"] != nil))
  func nativeCacheRestoresWithoutRepeatingSizeTraversal() async throws {
    let report = try #require(
      ProcessInfo.processInfo.environment["XSTATS_APP_CACHE_RESOURCE_REPORT"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheURL = directory.appendingPathComponent("inventory.json")
    let first = AppManagementController(brewAvailable: false, cacheURL: cacheURL)
    first.setVisible(true)
    try await waitFor { !first.isReading && !first.apps.isEmpty }
    let count = first.apps.count
    let sizeCount = first.sizes.count
    first.setVisible(false)
    let reads = AppManagementTestValue((list: 0, metadata: 0, sizes: 0))
    let restarted = AppManagementController(
      listApps: {
        reads.withLock { $0.list += 1 }
        return try AppUninstaller.scanInstalledApps()
      },
      inspectApp: { app in
        reads.withLock { $0.metadata += 1 }
        return ApplicationMetadata.read(app)
      },
      measureSize: { url in
        reads.withLock { $0.sizes += 1 }
        return try CleanEngine.scanAllocatedSize(of: url)
      }, brewAvailable: false, cacheURL: cacheURL)
    defer { restarted.setVisible(false) }
    let start = ContinuousClock.now
    restarted.setVisible(true)
    try await waitFor { !restarted.apps.isEmpty }
    let restored = start.duration(to: .now)
    #expect(restarted.apps.count == count && restarted.sizes.count == sizeCount)
    try await waitFor { !restarted.isReading }
    #expect(reads.withLock { $0.sizes } == 0)
    let beforeReopen = reads.withLock { $0 }
    var cpuBefore = rusage()
    getrusage(RUSAGE_SELF, &cpuBefore)
    let reopenStart = ContinuousClock.now
    for _ in 0..<10 {
      restarted.setVisible(false)
      restarted.setVisible(true)
      #expect(!restarted.isLoadingApps && !restarted.isRefreshingApps)
      try await waitFor { !restarted.isReading }
    }
    let reopenDuration = reopenStart.duration(to: .now)
    var cpuAfter = rusage()
    getrusage(RUSAGE_SELF, &cpuAfter)
    let reopenCPU =
      Double(
        cpuAfter.ru_utime.tv_sec + cpuAfter.ru_stime.tv_sec - cpuBefore.ru_utime.tv_sec
          - cpuBefore.ru_stime.tv_sec)
      + Double(
        cpuAfter.ru_utime.tv_usec + cpuAfter.ru_stime.tv_usec - cpuBefore.ru_utime.tv_usec
          - cpuBefore.ru_stime.tv_usec) / 1_000_000
    #expect(
      reads.withLock { $0.list == 1 && $0.metadata == beforeReopen.metadata && $0.sizes == 0 })
    restarted.setVisible(false)
    let before = reads.withLock { $0 }
    try await Task.sleep(for: .seconds(5))
    #expect(
      reads.withLock {
        $0.list == before.list && $0.metadata == before.metadata && $0.sizes == before.sizes
      })
    try
      "apps=\(count) cached_sizes=\(sizeCount) restored_in=\(restored) live_inventory_reads=\(before.list) metadata_reads=\(before.metadata) repeated_size_reads=\(before.sizes) reopen_count=10 reopen_new_reads=0 reopen_wall=\(reopenDuration) reopen_cpu_seconds=\(reopenCPU) closed_new_reads=0 observed_seconds=5\n"
      .write(toFile: report, atomically: true, encoding: .utf8)
  }

  /// 可选实机检查：只读真实清单，关闭页面后等待目录遍历退出，确认不再发起后台读取。
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["XSTATS_APP_MANAGEMENT_RESOURCE_REPORT"] != nil))
  func nativeInventoryStopsWhenClosed() async throws {
    let path = try #require(
      ProcessInfo.processInfo.environment["XSTATS_APP_MANAGEMENT_RESOURCE_REPORT"])
    let calls = AppManagementTestValue((apps: 0, brew: 0, sizes: 0, active: 0))
    let controller = AppManagementController(
      listApps: {
        calls.withLock { $0.apps += 1 }
        return try AppUninstaller.scanInstalledApps()
      },
      measureSize: { url in
        calls.withLock {
          $0.sizes += 1
          $0.active += 1
        }
        defer { calls.withLock { $0.active -= 1 } }
        return try CleanEngine.scanAllocatedSize(of: url)
      },
      listPackages: {
        calls.withLock { $0.brew += 1 }
        return try await HomebrewManagement.inventory()
      })
    defer { controller.setVisible(false) }
    controller.setVisible(true)
    try await waitFor { !controller.apps.isEmpty && controller.hasBrewInventory }
    let appCount = controller.apps.count
    let packageCount = controller.packages.count
    controller.setVisible(false)
    try await waitFor { calls.withLock { $0.active == 0 } }
    let before = calls.withLock { $0 }
    var cpuBefore = rusage()
    getrusage(RUSAGE_SELF, &cpuBefore)
    try await Task.sleep(for: .seconds(5))
    var cpuAfter = rusage()
    getrusage(RUSAGE_SELF, &cpuAfter)
    #expect(
      calls.withLock {
        $0.apps == before.apps && $0.brew == before.brew && $0.sizes == before.sizes
          && $0.active == 0
      })
    let cpu =
      Double(
        cpuAfter.ru_utime.tv_sec + cpuAfter.ru_stime.tv_sec - cpuBefore.ru_utime.tv_sec
          - cpuBefore.ru_stime.tv_sec)
      + Double(
        cpuAfter.ru_utime.tv_usec + cpuAfter.ru_stime.tv_usec - cpuBefore.ru_utime.tv_usec
          - cpuBefore.ru_stime.tv_usec) / 1_000_000
    try
      "apps=\(appCount) packages=\(packageCount) closed_new_reads=0 closed_cpu_seconds=\(cpu) observed_seconds=5\n"
      .write(toFile: path, atomically: true, encoding: .utf8)
  }
}

private actor StoreLookupGate {
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

// 测试回调跨线程共享的计数和信号，只允许在锁内访问。
private final class AppManagementTestValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func withLock<T>(_ work: (inout Value) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return work(&value)
  }
}
