// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner
@testable import XStatsUI

@MainActor
struct UninstallerScanLifecycleTests {
  @Test func verifiedListAppearsBeforeBackgroundSizeMeasurementFinishes() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UninstallProgress-\(UUID())"
    ).resolvingSymlinksInPath()
    let appURL = home.appendingPathComponent("Applications/Fixture.app")
    let info = appURL.appendingPathComponent("Contents/Info.plist")
    let cache = home.appendingPathComponent("Library/Caches/com.example.scanprogress")
    try FileManager.default.createDirectory(
      at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "com.example.scanprogress"], format: .xml, options: 0
    ).write(to: info)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let app = try #require(AppUninstaller.app(at: appURL))
    let gate = ScanGate()
    let controller = UninstallerController(
      currentBundleIdentifier: nil, home: home.path,
      measureSize: { _ in
        _ = gate.increment()
        gate.markStarted()
        _ = gate.release.wait(timeout: .now() + 10)
        try Task.checkCancellation()
        return 4096
      })
    let task = controller.select(app)
    defer {
      gate.release.signal()
      gate.release.signal()
      controller.cancelScanning()
      try? FileManager.default.removeItem(at: home)
    }
    let deadline = ContinuousClock.now + .seconds(10)
    while controller.isScanning, !gate.hasStarted, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(gate.hasStarted, "残留列表的大小应由独立后台计量执行")
    #expect(Set(controller.leftovers.map(\.url.path)) == [appURL.path, cache.path])
    #expect(controller.isScanning && !controller.canUninstall)
    #expect(controller.scanStage == .sizes)
    #expect(controller.leftovers.allSatisfy { !$0.isSizeKnown })
    let body = try #require(controller.leftovers.first { $0.kind == .application })
    let cacheItem = try #require(controller.leftovers.first { $0.kind == .caches })
    controller.toggle(cacheItem)
    gate.release.signal()
    gate.release.signal()
    await task?.value
    #expect(controller.canUninstall && !controller.isScanning)
    #expect(controller.chosen == [body.id])
    #expect(controller.chosenSize == 4096)
    #expect(gate.calls == 2)
    #expect(controller.scanStage == nil)
  }

  @Test func lateSizeCannotOverwriteNewScanOfSameApplication() async throws {
    let target = app()
    let gate = ScanGate()
    let controller = UninstallerController(
      currentBundleIdentifier: nil,
      findLeftoversReport: { app in
        AppLeftoverScan(items: [
          AppLeftover(url: app.url, kind: .application, size: 0, isSizeKnown: false)
        ])
      },
      measureSize: { _ in
        if gate.increment() == 1 {
          gate.markStarted()
          _ = gate.release.wait(timeout: .now() + 10)
          // 模拟不响应取消的底层文件调用，晚到结果仍须被代际检查丢弃。
          return 100
        }
        return 800
      })
    defer {
      gate.release.signal()
      controller.cancelScanning()
    }
    let old = controller.select(target)
    let started = try await gate.waitUntilStarted()
    try #require(started)
    await controller.select(target)?.value
    #expect(controller.chosenSize == 800 && controller.canUninstall)
    gate.release.signal()
    await old?.value
    #expect(controller.chosenSize == 800 && controller.canUninstall)
    #expect(controller.scanStage == nil)
  }

  @Test func closingDuringSizeMeasurementCancelsWorkAndRequiresFreshScan() async throws {
    let gate = ScanGate()
    let target = app()
    let controller = UninstallerController(
      currentBundleIdentifier: nil,
      findLeftoversReport: { app in
        AppLeftoverScan(items: [
          AppLeftover(url: app.url, kind: .application, size: 0, isSizeKnown: false)
        ])
      },
      measureSize: { _ in
        if gate.increment() == 1 {
          gate.markStarted()
          while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
          gate.markFinished()
          throw CancellationError()
        }
        return 500
      })
    defer { controller.cancelScanning() }
    let task = controller.select(target)
    let started = try await gate.waitUntilStarted()
    try #require(started)
    controller.cancelScanning()
    await task?.value
    #expect(gate.finished && !controller.isScanning && controller.scanStage == nil)
    #expect(!controller.canUninstall && controller.leftovers.allSatisfy { !$0.isSizeKnown })
    controller.resumeSelectionScan()
    let deadline = ContinuousClock.now + .seconds(10)
    while controller.isScanning, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.canUninstall && controller.chosenSize == 500)
    #expect(gate.calls == 2)
  }

  @Test(arguments: [false, true])
  func unreadableSizeNeverBecomesAZeroByteRemovalCandidate(_ applicationFails: Bool) async {
    let target = app()
    let cache = URL(fileURLWithPath: "/tmp/scan-unreadable-\(UUID())")
    let controller = UninstallerController(
      currentBundleIdentifier: nil,
      findLeftoversReport: { app in
        AppLeftoverScan(items: [
          AppLeftover(url: app.url, kind: .application, size: 0, isSizeKnown: false),
          AppLeftover(url: cache, kind: .caches, size: 0, isSizeKnown: false),
        ])
      },
      measureSize: { url in
        if url == cache || applicationFails { throw CocoaError(.fileReadNoPermission) }
        return 512
      })
    defer { controller.cancelScanning() }
    await controller.select(target)?.value
    #expect(!controller.isScanning && controller.scanStage == nil)
    if applicationFails {
      #expect(!controller.canUninstall && controller.outcome?.isError == true)
    } else {
      #expect(controller.canUninstall && controller.scanIncomplete)
      #expect(controller.chosen == [target.id] && controller.chosenSize == 512)
      #expect(controller.leftovers.allSatisfy { $0.isSizeKnown })
    }
  }

  @Test func featureDisableCancelsScanAndRejectsItsLateResult() async throws {
    let gate = ScanGate()
    let controller = UninstallerController(
      currentBundleIdentifier: nil,
      findLeftovers: { app in
        gate.markStarted()
        _ = gate.release.wait(timeout: .now() + 30)
        gate.markFinished()
        return [AppLeftover(url: app.url, kind: .application, size: 1)]
      })
    defer {
      gate.release.signal()
      controller.cancelScanning()
    }
    controller.select(app())
    let started = try await gate.waitUntilStarted()
    try #require(started)
    controller.setEnabled(false)
    controller.setEnabled(true)
    gate.release.signal()
    let deadline = ContinuousClock.now + .seconds(120)
    while !gate.finished, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(gate.finished)
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.leftovers.isEmpty && controller.selected == nil)
    #expect(!controller.isScanning && !controller.canUninstall)
  }

  private func app() -> InstalledApp {
    InstalledApp(
      url: URL(fileURLWithPath: "/Applications/Scan-\(UUID()).app"), name: "ScanFixture",
      bundleIdentifier: "test.scan.fixture", version: nil, teamIdentifier: nil)
  }

  @Test func obsoleteScanOfSameApplicationCannotOverwriteNewChoices() async throws {
    let target = app()
    let gate = ScanGate()
    let body = AppLeftover(url: target.url, kind: .application, size: 100)
    let cache = AppLeftover(url: URL(fileURLWithPath: "/tmp/scan-cache"), kind: .caches, size: 100)
    let controller = UninstallerController(
      currentBundleIdentifier: nil,
      findLeftovers: { _ in
        if gate.increment() == 1 {
          gate.markStarted()
          _ = gate.release.wait(timeout: .now() + 30)
          gate.markFinished()
        }
        return [body, cache]
      })
    defer {
      gate.release.signal()
      controller.cancelScanning()
    }
    controller.select(target)
    let started = try await gate.waitUntilStarted()
    try #require(started)
    controller.select(target)
    let deadline = ContinuousClock.now + .seconds(120)
    while controller.isScanning, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!controller.isScanning)
    controller.toggle(cache)
    #expect(!controller.chosen.contains(cache.id))
    gate.release.signal()
    while !gate.finished, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(gate.finished)
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.selected == target)
    #expect(controller.chosen == [body.id])
  }

  @Test func sizeCalculationIsSingleAndStopsWhenPageLeaves() async throws {
    let target = app()
    let listCalls = ScanGate()
    let measureCalls = ScanGate()
    let controller = UninstallerController(
      currentBundleIdentifier: nil,
      listApplications: {
        _ = listCalls.increment()
        return [target]
      },
      measureSize: { _ in
        if measureCalls.increment() == 1 {
          measureCalls.markStarted()
          while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
          measureCalls.markFinished()
          throw CancellationError()
        }
        return 321
      })
    defer { controller.cancelScanning() }
    controller.loadApps()
    let started = try await measureCalls.waitUntilStarted()
    try #require(started)
    // 列表发布后即结束"正在扫描"，大小计量在后台继续。
    #expect(!controller.isLoading && controller.apps == [target])
    controller.loadApps()
    #expect(listCalls.calls == 1)
    controller.cancelScanning()
    #expect(!controller.isLoading && !controller.isScanning)
    let deadline = ContinuousClock.now + .seconds(120)
    while !measureCalls.finished, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(measureCalls.finished)
    #expect(controller.sizes[target.id] == nil)
    controller.resumeScanning()
    while controller.sizes[target.id] == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!controller.isLoading)
    #expect(controller.sizes[target.id] == 321)
    #expect(listCalls.calls == 2 && measureCalls.calls == 2)
  }

  @Test func explicitReloadRelistsDuringMeasurementAndKeepsKnownSizes() async throws {
    let measured = app()
    let slow = app()
    let listCalls = ScanGate()
    let slowCalls = ScanGate()
    let measuredCalls = ScanGate()
    let controller = UninstallerController(
      currentBundleIdentifier: nil,
      listApplications: {
        _ = listCalls.increment()
        return [measured, slow]
      },
      measureSize: { url in
        if url == measured.url {
          _ = measuredCalls.increment()
          return 100
        }
        if slowCalls.increment() == 1 {
          slowCalls.markStarted()
          while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
          slowCalls.markFinished()
          throw CancellationError()
        }
        return 200
      })
    defer { controller.cancelScanning() }
    controller.loadApps()
    let started = try await slowCalls.waitUntilStarted()
    try #require(started)
    controller.reloadApps()
    let deadline = ContinuousClock.now + .seconds(120)
    while controller.sizes[slow.id] == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    // 新计量发布与旧子任务退出没有先后保证，须分别等待取消收尾。
    while !slowCalls.finished, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(listCalls.calls == 2, "计量未完成时显式刷新也必须重新列举")
    #expect(slowCalls.finished, "被中断的计量必须响应取消")
    #expect(controller.sizes[measured.id] == 100 && controller.sizes[slow.id] == 200)
    #expect(measuredCalls.calls == 1, "已算出的大小不应重复计量")
  }

  @Test func clearingSelectionCancelsWorkAndResetsScanningState() async throws {
    let gate = ScanGate()
    let controller = UninstallerController(
      currentBundleIdentifier: nil,
      findLeftovers: { _ in
        gate.markStarted()
        while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        gate.markFinished()
        throw CancellationError()
      })
    defer { controller.cancelScanning() }
    controller.select(app())
    let started = try await gate.waitUntilStarted()
    try #require(started)
    controller.select(nil)
    #expect(controller.selected == nil && !controller.isScanning)
    let deadline = ContinuousClock.now + .seconds(120)
    while !gate.finished, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(gate.finished && controller.leftovers.isEmpty)
  }
}

/// 同步扫描边界的测试闸门；可变计数与完成状态均由锁保护。
private final class ScanGate: @unchecked Sendable {
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var count = 0
  private var done = false
  private var started = false
  var calls: Int { lock.withLock { count } }
  var finished: Bool { lock.withLock { done } }
  var hasStarted: Bool { lock.withLock { started } }
  func increment() -> Int {
    lock.withLock {
      count += 1
      return count
    }
  }
  func markFinished() { lock.withLock { done = true } }
  func markStarted() { lock.withLock { started = true } }
  func waitUntilStarted() async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(120)
    while !lock.withLock({ started }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    return lock.withLock { started }
  }
}
