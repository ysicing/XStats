// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import XStatsUI

@MainActor
struct LauncherCacheTests {
  @Test func catalogIncludesRegisteredClonesByNameWhenEnabled() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? files.removeItem(at: root) }
    let store = AppCloneStore(root: root)
    let clone = AppClone(id: UUID(), number: 42, application: .qq, name: "工作号")
    let named = store.bundleURL(clone)
    let directory = named.deletingLastPathComponent()
    let legacy = directory.appending(path: "\(clone.engineName).app")
    let contents = legacy.appending(path: "Contents")
    try files.createDirectory(at: contents, withIntermediateDirectories: true)
    let registration = directory.appending(path: "clone.json")
    let encoded = try JSONEncoder().encode(clone)
    let atLimit = encoded + Data(repeating: 32, count: 4096 - encoded.count)
    try atLimit.write(to: registration)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": clone.bundleID], format: .xml, options: 0)
    try plist.write(to: contents.appending(path: "Info.plist"))
    let manuallyIndexed = AppCommand(
      id: "application.\(legacy.path)", title: clone.engineName, symbol: "app",
      keywords: "", action: .openApplication(legacy))
    let empty = LauncherApplicationSnapshot(commands: [], isTruncated: false)
    let disabled = try await empty.includingAppClones(enabled: false, store: store)
    #expect(disabled.commands.isEmpty)
    #expect(disabled.hidesAppClones)

    let snapshot = LauncherApplicationSnapshot(commands: [manuallyIndexed], isTruncated: false)
    let indexed = try await snapshot.includingAppClones(enabled: true, store: store)
    let command = try #require(indexed.commands.first)
    #expect(indexed.commands.count == 1)
    #expect(command.action == .openApplication(store.bundleURL(clone).standardizedFileURL))
    let search = CommandBarSearch(commands: indexed.commands)
    #expect(search.results(for: "工作号").map(\.id) == [command.id])
    #expect(search.results(for: "QQ").map(\.id) == [command.id])
    #expect(!indexed.hidesAppClones)

    try (atLimit + Data([32])).write(to: registration)
    #expect(try await store.list().isEmpty)
    try encoded.write(to: registration)

    try files.moveItem(at: legacy, to: named)
    let updated = try await empty.includingAppClones(enabled: true, store: store)
    #expect(updated.commands.first?.id == command.id)
    #expect(
      updated.commands.first?.action == .openApplication(store.bundleURL(clone).standardizedFileURL)
    )
    try files.removeItem(at: named)
    #expect(try await empty.includingAppClones(enabled: true, store: store).commands.isEmpty)
  }

  @Test func oversizedCloneRegistrationFailsBeforeCreatingFiles() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString)
    let store = AppCloneStore(root: root)
    let name = "a" + String(repeating: "\u{0301}", count: 2048)
    let clone = AppClone(id: UUID(), number: 42, application: .qq, name: name)
    #expect(name.count == 1)
    await #expect(throws: AppCloneStore.Failure.registrationTooLarge) {
      try await store.build(clone, source: root.appending(path: "QQ.app"), updating: false)
    }
    #expect(!files.fileExists(atPath: root.path))
  }

  @Test func catalogReusesFreshResultsAndRefreshesOnExpiryOrInvalidation() async throws {
    let loader = CatalogCounter()
    var now: TimeInterval = 0
    let catalog = LauncherApplicationCatalog(
      clock: { now }, loader: { await loader.load() })
    _ = try await catalog.load()
    now = 29
    _ = try await catalog.load()
    #expect(await loader.count == 1)
    now = 30
    _ = try await catalog.load()
    #expect(await loader.count == 2)
    _ = try await catalog.load(force: true)
    #expect(await loader.count == 3)
    catalog.invalidate()
    _ = try await catalog.load()
    #expect(await loader.count == 4)
  }

  @Test func concurrentRequestsShareWorkAndCancelledConsumerDoesNotCancelOthers() async throws {
    let loader = SuspendedCatalogLoader()
    let catalog = LauncherApplicationCatalog(loader: { try await loader.load() })
    let first = Task { try await catalog.load() }
    let second = Task { try await catalog.load() }
    try await loader.waitForRequests(1)
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    await loader.finish()
    #expect(try await second.value.commands.first?.id == "1")
    #expect(await loader.count == 1)
    #expect(try await catalog.load().commands.first?.id == "1")
  }

  @Test func invalidatedWorkCannotRepopulateCache() async throws {
    let loader = SuspendedCatalogLoader()
    let catalog = LauncherApplicationCatalog(loader: { try await loader.load() })
    let stale = Task { try await catalog.load() }
    try await loader.waitForRequests(1)
    catalog.invalidate()
    await #expect(throws: CancellationError.self) { try await stale.value }
    let fresh = Task { try await catalog.load() }
    try await loader.waitForRequests(2)
    await loader.finish()
    #expect(try await fresh.value.commands.first?.id == "2")
    #expect(try await catalog.load().commands.first?.id == "2")
  }

  @Test func closingLastConsumerCancelsWorkAndReopenStartsFreshScan() async throws {
    let loader = SuspendedCatalogLoader()
    let catalog = LauncherApplicationCatalog(loader: { try await loader.load() })
    let abandoned = Task { try await catalog.load() }
    try await loader.waitForRequests(1)
    abandoned.cancel()
    await #expect(throws: CancellationError.self) { try await abandoned.value }
    let reopened = Task { try await catalog.load() }
    try await loader.waitForRequests(2)
    await loader.finish()
    #expect(try await reopened.value.commands.first?.id == "2")
    #expect(await loader.cancellations == 1)
  }

  @Test func failedScanDoesNotPreventRetry() async throws {
    let loader = CatalogCounter()
    let catalog = LauncherApplicationCatalog(loader: {
      let result = await loader.load()
      if await loader.count == 1 { throw CocoaError(.fileReadNoPermission) }
      return result
    })
    await #expect(throws: CocoaError.self) { try await catalog.load() }
    _ = try await catalog.load()
    #expect(await loader.count == 2)
  }

  @Test func iconCacheEvictsLeastRecentlyUsedAndReturnsIndependentSizes() {
    var loads = 0
    let cache = LauncherIconCache(
      capacity: 2,
      loader: { _ in
        loads += 1
        return NSImage(size: NSSize(width: 512, height: 512))
      })
    let first = URL(fileURLWithPath: "/tmp/first.app")
    let second = URL(fileURLWithPath: "/tmp/second.app")
    let third = URL(fileURLWithPath: "/tmp/third.app")
    let icon = cache.image(for: first, size: 32)
    _ = cache.image(for: second, size: 32)
    #expect(cache.image(for: first, size: 32) === icon)
    _ = cache.image(for: third, size: 32)
    #expect(loads == 3)
    _ = cache.image(for: second, size: 32)
    #expect(loads == 4)
    let larger = cache.image(for: first, size: 64)
    #expect(icon.size.width == 32 && larger.size.width == 64)
    #expect(larger.representations.allSatisfy { $0.pixelsWide <= 128 })
    cache.invalidate()
    _ = cache.image(for: first, size: 64)
    #expect(loads == 6)
  }

  @Test func iconCacheRechecksChangesOnlyAfterInterval() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var now: TimeInterval = 0
    var loads = 0
    let cache = LauncherIconCache(
      clock: { now },
      loader: { _ in
        loads += 1
        return NSImage(size: NSSize(width: 64, height: 64))
      })
    _ = cache.image(for: root, size: 32)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 42)], ofItemAtPath: root.path)
    _ = cache.image(for: root, size: 32)
    #expect(loads == 1)
    now = 30
    _ = cache.image(for: root, size: 32)
    #expect(loads == 2)
  }

  @Test func changingIconResourceInvalidatesThumbnailWithoutChangingBundleDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let contents = root.appendingPathComponent("Contents")
    let resources = contents.appendingPathComponent("Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIconFile": "Icon"], format: .xml, options: 0)
    try info.write(to: contents.appendingPathComponent("Info.plist"))
    let icon = resources.appendingPathComponent("Icon.icns")
    try Data([0]).write(to: icon)
    var now: TimeInterval = 0
    var loads = 0
    let cache = LauncherIconCache(
      clock: { now },
      loader: { _ in
        loads += 1
        return NSImage(size: NSSize(width: 64, height: 64))
      })
    _ = cache.image(for: root, size: 32)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 42)], ofItemAtPath: icon.path)
    now = 30
    _ = cache.image(for: root, size: 32)
    #expect(loads == 2)
  }
}

private actor CatalogCounter {
  private(set) var count = 0
  func load() -> LauncherApplicationSnapshot {
    count += 1
    return LauncherApplicationSnapshot(commands: [], isTruncated: false)
  }
}

private actor SuspendedCatalogLoader {
  private(set) var count = 0
  private(set) var cancellations = 0
  private var continuations: [Int: CheckedContinuation<LauncherApplicationSnapshot, any Error>] =
    [:]

  func load() async throws -> LauncherApplicationSnapshot {
    count += 1
    let request = count
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuations[request] = $0 }
    } onCancel: {
      Task { await self.recordCancellation() }
    }
  }

  private func recordCancellation() { cancellations += 1 }

  func waitForRequests(_ expected: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while count < expected && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(count == expected)
  }

  func finish() {
    for (request, continuation) in continuations {
      continuation.resume(
        returning: LauncherApplicationSnapshot(
          commands: [
            AppCommand(
              id: String(request), title: "App", symbol: "app", keywords: "",
              action: .openApplication(URL(fileURLWithPath: "/tmp/App.app")))
          ], isTruncated: false))
    }
    continuations.removeAll()
  }
}
