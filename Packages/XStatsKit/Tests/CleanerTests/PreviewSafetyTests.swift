// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct PreviewSafetyTests {
  @Test func hardLinkOrderingDoesNotConsumeDirectoryEntryBudget() async throws {
    let home = try Fixture()
    defer { home.remove() }
    for index in 0..<6 {
      let file = try home.file("Library/Caches/linked/\(index)")
      try FileManager.default.linkItem(
        at: file, to: home.root.appendingPathComponent("outside-\(index)"))
    }
    let cache = home.root.appendingPathComponent("Library/Caches/linked")
    var environment = home.environment
    environment.scanLimits = ScanLimits(maxEntries: 7)
    let scan = await boundedScan(rule(urls: [cache]), environment: environment)
    #expect(scan.isComplete)
    #expect(scan.items.map(\.url) == [cache])
  }

  @Test func directoryScansFinishWithoutEntryOrCandidateQuotas() async throws {
    let home = try Fixture()
    defer { home.remove() }
    for index in 0..<4 { _ = try home.file("Downloads/\(index).dmg") }
    let cache = try home.file("Library/Caches/large/nested/data").deletingLastPathComponent()
    var environment = home.environment
    environment.scanLimits = ScanLimits(maxEntries: 0, maxDuration: 0, maxCandidates: 0)
    let scans = await CleanEngine.scan(
      [RuleCatalog.installers, rule(id: "cache", urls: [cache])], environment: environment)
    #expect(scans.count == 2)
    #expect(scans.allSatisfy { $0.isComplete })
    #expect(scans[0].items.count == 4)
    #expect(scans[1].items.map(\.url) == [cache])
    #expect(scans[1].totalSize == (try CleanEngine.scanAllocatedSize(of: cache)))
  }

  @Test(arguments: [
    (0, 64, 2), (1, 64, 2), (2, 64, 2), (3, 64, 2), (4, 64, 2), (5, 64, 2),
    (6, 64, 3), (8, 64, 4), (11, 64, 5), (16, 64, 8), (32, 1, 1), (32, 0, 0),
  ])
  func scanConcurrencyFollowsAvailableProcessors(
    processors: Int, ruleCount: Int, expected: Int
  ) async throws {
    let home = try Fixture()
    defer { home.remove() }
    let activity = ScanActivity()
    let rules = (0..<ruleCount).map { index in
      CleanRule(
        id: "concurrent.\(index)", category: .developer, title: "Fixture", detail: "",
        symbol: "archivebox", requiredTool: "fixture",
        prepareTool: { _ in
          await activity.enter()
          try await Task.sleep(for: .milliseconds(20))
          await activity.leave()
          return ToolCachePlan(roots: [], tool: "fixture", arguments: [])
        })
    }
    var environment = home.environment
    environment.activeProcessorCount = processors
    let clock = VisitCounter()
    environment.concurrencyUptime = { Double(clock.tick() * 4) }
    environment.scanLoad = { .init(cpuUsage: 0.2, memoryPressure: .normal) }
    environment.isToolAvailable = { _ in true }
    let scans = await CleanEngine.scan(rules, environment: environment)
    #expect(scans.map(\.id) == rules.map(\.id))
    #expect(scans.allSatisfy { $0.isComplete })
    #expect(await activity.peak == expected)
    #expect(await activity.active == 0)
  }

  @Test func cancellingAdaptiveScanStopsActiveToolsAndLeavesQueuedRulesUnstarted() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let activity = ScanActivity()
    let (starts, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    let rules = (0..<12).map { index in
      CleanRule(
        id: "cancel.\(index)", category: .developer, title: "Fixture", detail: "",
        symbol: "archivebox", requiredTool: "fixture",
        prepareTool: { _ in
          await activity.enter()
          continuation.yield(())
          do {
            try await Task.sleep(for: .seconds(5))
          } catch {
            await activity.leave()
            throw error
          }
          await activity.leave()
          return ToolCachePlan(roots: [], tool: "fixture", arguments: [])
        })
    }
    var environment = home.environment
    environment.activeProcessorCount = 8
    environment.isToolAvailable = { _ in true }
    environment.scanLimits = ScanLimits(maxDuration: 1)
    let scanEnvironment = environment
    let task = Task {
      let scans = await CleanEngine.scan(rules, environment: scanEnvironment)
      continuation.finish()
      return scans
    }
    var started = 0
    for await _ in starts {
      started += 1
      if started == 2 { break }
    }
    task.cancel()
    let scans = await task.value
    #expect(started == 2)
    #expect(scans.map(\.id) == ["cancel.0", "cancel.1"])
    #expect(scans.allSatisfy { $0.interruption == .cancelled })
    #expect(await activity.peak == 2)
    #expect(await activity.active == 0)
  }

  @Test func cancellationWhilePressurePausedDoesNotStartQueuedRules() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let (samples, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    let activity = ScanActivity()
    let rule = CleanRule(
      id: "paused", category: .developer, title: "Fixture", detail: "", symbol: "archivebox",
      requiredTool: "fixture",
      prepareTool: { _ in
        await activity.enter()
        await activity.leave()
        return ToolCachePlan(roots: [], tool: "fixture", arguments: [])
      })
    var environment = home.environment
    environment.scanLoad = {
      continuation.yield(())
      return .init(cpuUsage: 0.1, memoryPressure: .critical)
    }
    let scanEnvironment = environment
    let task = Task { await CleanEngine.scan([rule], environment: scanEnvironment) }
    for await _ in samples { break }
    task.cancel()
    #expect(await task.value.isEmpty)
    #expect(await activity.peak == 0)
  }

  @Test func pressurePauseCanRecoverWhenNoTasksAreActive() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let samples = EntryCounter()
    var environment = home.environment
    environment.scanLoad = {
      await samples.record(1)
      let count = await samples.counts.count
      return .init(cpuUsage: 0.2, memoryPressure: count == 1 ? .critical : .normal)
    }
    let scans = await CleanEngine.scan([rule(urls: [])], environment: environment)
    #expect(scans.count == 1)
    #expect(scans[0].isComplete)
    #expect(await samples.counts.count >= 2)
  }

  @Test func loadDropDrainsActiveTasksAndEventuallyFinishesTheQueue() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let activity = ScanActivity()
    let samples = EntryCounter()
    let clock = VisitCounter()
    let rules = (0..<16).map { index in
      CleanRule(
        id: "drain.\(index)", category: .developer, title: "Fixture", detail: "",
        symbol: "archivebox", requiredTool: "fixture",
        prepareTool: { _ in
          await activity.enter()
          try await Task.sleep(for: .milliseconds(30))
          await activity.leave()
          return ToolCachePlan(roots: [], tool: "fixture", arguments: [])
        })
    }
    var environment = home.environment
    environment.activeProcessorCount = 16
    environment.isToolAvailable = { _ in true }
    environment.concurrencyUptime = { Double(clock.tick() * 4) }
    environment.scanLoad = {
      await samples.record(1)
      let count = await samples.counts.count
      return .init(
        cpuUsage: count <= 2 ? 0.2 : 0.9,
        memoryPressure: (3...5).contains(count) ? .critical : .normal)
    }
    let scans = await CleanEngine.scan(rules, environment: environment)
    #expect(scans.map(\.id) == rules.map(\.id))
    #expect(scans.allSatisfy { $0.isComplete })
    // 已完成但尚未收取的任务仍占组内名额，实际执行峰值可能低于派发上限。
    #expect((2...3).contains(await activity.peak))
    #expect(await activity.active == 0)
    #expect(await samples.counts.count > 5)
  }

  @Test func shortRulesDoNotReadLoadForEveryCompletion() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let samples = EntryCounter()
    var environment = home.environment
    environment.concurrencyUptime = { 0 }
    environment.scanLoad = {
      await samples.record(1)
      return .init(cpuUsage: 0.2, memoryPressure: .normal)
    }
    let scans = await CleanEngine.scan(
      (0..<32).map { rule(id: "short.\($0)", urls: []) }, environment: environment)
    #expect(scans.count == 32)
    #expect(scans.allSatisfy { $0.isComplete })
    #expect(await samples.counts.count == 1)
  }

  @Test func directoryCompletesAlongsideEmptyRules() async throws {
    let home = try Fixture()
    defer { home.remove() }
    for index in 0..<15 { _ = try home.file("Library/Caches/large/\(index)") }
    let root = home.root.appendingPathComponent("Library/Caches/large")
    var environment = home.environment
    environment.scanLimits = ScanLimits(maxEntries: 60)
    let scans = await CleanEngine.scan(
      [rule(id: "large", urls: [root])]
        + (0..<4).map { rule(id: "empty.\($0)", urls: []) },
      environment: environment)
    #expect(scans.count == 5)
    #expect(scans.allSatisfy { $0.isComplete })
    #expect(scans[0].items.map(\.url) == [root])
  }

  @Test func toolDirectoryIsMeasuredWithoutRepeatingItsNativePreview() async throws {
    let home = try Fixture()
    defer { home.remove() }
    for index in 0..<15 { _ = try home.file("Library/Caches/large/\(index)") }
    let root = home.root.appendingPathComponent("Library/Caches/large")
    let counter = EntryCounter()
    let tool = CleanRule(
      id: "tool", category: .developer, title: "Fixture", detail: "", symbol: "archivebox",
      requiredTool: "fixture",
      prepareTool: { _ in
        await counter.record(1)
        return ToolCachePlan(roots: [root], tool: "fixture", arguments: [])
      })
    var environment = home.environment
    environment.isToolAvailable = { _ in true }
    environment.scanLimits = ScanLimits(maxEntries: 60)
    let scans = await CleanEngine.scan(
      [tool] + (0..<4).map { rule(id: "empty.\($0)", urls: []) },
      environment: environment)
    #expect(scans[0].isComplete)
    #expect(scans[0].items.map(\.url) == [root])
    #expect(await counter.counts == [1])
  }

  @Test(arguments: [4, 8, 16])
  func directoryDiscoveryRunsOnceWithoutQuotaRestarts(processors: Int) async throws {
    let home = try Fixture()
    defer { home.remove() }
    let visits = VisitCounter()
    let large = CleanRule(
      id: "large", category: .system, title: "Fixture", detail: "", symbol: "archivebox"
    ) { _ in
      visits.start()
      let budget = try #require(ScanBudget.current)
      for _ in 0..<100_001 {
        try budget.visit()
        visits.visit()
      }
      return []
    }
    var environment = home.environment
    environment.activeProcessorCount = processors
    environment.scanLimits = ScanLimits(maxEntries: 60)
    let scans = await CleanEngine.scan(
      [large] + (0..<4).map { rule(id: "empty.\($0)", urls: []) },
      environment: environment)
    #expect(visits.snapshot == [1, 100_001])
    #expect(scans[0].isComplete)
    #expect(scans.dropFirst().allSatisfy { $0.isComplete })
  }

  @Test func cancellationDuringLongDirectoryDiscoveryStopsFurtherReads() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let visits = VisitCounter()
    let directory = CleanRule(
      id: "cancelled", category: .system, title: "Fixture", detail: "", symbol: "archivebox"
    ) { _ in
      let budget = try #require(ScanBudget.current)
      for index in 0..<100_001 {
        if index == 100 { withUnsafeCurrentTask { $0?.cancel() } }
        try budget.visit()
        visits.visit()
      }
      return []
    }
    var environment = home.environment
    environment.scanLimits = ScanLimits(maxEntries: 0, maxCandidates: 0)
    let scans = await CleanEngine.scan([directory], environment: environment)
    #expect(visits.snapshot == [0, 100])
    #expect(scans.count == 1)
    #expect(scans[0].interruption == .cancelled)
    #expect(!scans[0].isComplete && scans[0].items.isEmpty)
  }

  @Test(arguments: [4, 8, 16])
  func directoryRulesDoNotShareAnEntryQuota(processors: Int) async throws {
    let home = try Fixture()
    defer { home.remove() }
    let counter = EntryCounter()
    let rules = (0..<4).map { index in
      CleanRule(
        id: "budget.\(index)", category: .developer, title: "Fixture", detail: "",
        symbol: "archivebox", requiredTool: "fixture",
        prepareTool: { _ in
          let budget = try #require(ScanBudget.current)
          var visited = 0
          do {
            for _ in 0..<100 {
              try budget.visit()
              visited += 1
            }
          } catch is ScanInterruption {}
          await counter.record(visited)
          return ToolCachePlan(roots: [], tool: "fixture", arguments: [])
        })
    }
    var environment = home.environment
    environment.activeProcessorCount = processors
    environment.isToolAvailable = { _ in true }
    environment.scanLimits = ScanLimits(maxEntries: 20, maxDuration: 20)
    let scans = await CleanEngine.scan(rules, environment: environment)
    let counts = await counter.counts
    #expect(counts.count == 4)
    #expect(counts.allSatisfy { $0 > 0 })
    #expect(counts == [100, 100, 100, 100])
    #expect(scans.allSatisfy { $0.isComplete })
  }

  @Test func queuedDirectoriesCompleteDespiteSmallConfiguredLimits() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let root = try home.file("Library/Caches/small/first").deletingLastPathComponent()
    _ = try home.file("Library/Caches/small/second")
    var environment = home.environment
    environment.scanLimits = ScanLimits(maxEntries: 6, maxDuration: 20)
    let scans = await CleanEngine.scan(
      [
        rule(id: "empty.first", urls: []), rule(id: "empty.second", urls: []),
        rule(id: "small", urls: [root]),
      ], environment: environment)
    #expect(scans.allSatisfy { $0.isComplete })
    #expect(scans[2].items.map(\.url) == [root])
  }

  @Test func queuedRuleGetsTimeEvenAfterEarlierBudgetExpires() {
    let earlier = ScanBudget(limits: ScanLimits(maxDuration: 0))
    #expect(earlier.interruption == .timeLimit)
    let queued = ScanBudget(limits: ScanLimits(maxDuration: 20))
    #expect(queued.interruption == nil)
  }

  @Test func timedOutRulesDoNotPreventQueuedRulesFromScanning() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let root = try home.file("Downloads/fixture/data").deletingLastPathComponent()
    let slow = (0..<2).map { index in
      CleanRule(
        id: "slow.\(index)", category: .developer, title: "Fixture", detail: "",
        symbol: "archivebox", requiredTool: "fixture",
        prepareTool: { _ in
          try await Task.sleep(for: .seconds(2))
          return ToolCachePlan(roots: [], tool: "fixture", arguments: [])
        })
    }
    var environment = home.environment
    environment.isToolAvailable = { _ in true }
    environment.scanLimits = ScanLimits(maxDuration: 0.5)
    let scans = await CleanEngine.scan(
      slow + [rule(id: "download", urls: [root]), rule(id: "empty", urls: [])],
      environment: environment)
    #expect(scans.count == 4)
    #expect(scans.prefix(2).allSatisfy { $0.interruption == .timeLimit && !$0.isCleanable })
    #expect(scans[2].isComplete && scans[2].items.map(\.url) == [root])
    #expect(scans[3].isComplete)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("data").path))
  }

  @Test func cancellingScanDoesNotStartQueuedRules() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let (started, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    let slow = (0..<2).map { index in
      CleanRule(
        id: "slow.\(index)", category: .developer, title: "Fixture", detail: "",
        symbol: "archivebox", requiredTool: "fixture",
        prepareTool: { _ in
          continuation.yield(())
          try await Task.sleep(for: .seconds(30))
          return ToolCachePlan(roots: [], tool: "fixture", arguments: [])
        })
    }
    let queued = CleanRule(
      id: "queued", category: .system, title: "Fixture", detail: "", symbol: "archivebox"
    ) { _ in
      Issue.record("Cancellation must prevent queued rules from starting")
      return []
    }
    var environment = home.environment
    environment.isToolAvailable = { _ in true }
    let scanEnvironment = environment
    let task = Task { await CleanEngine.scan(slow + [queued], environment: scanEnvironment) }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    _ = await iterator.next()
    task.cancel()
    let scans = await task.value
    #expect(scans.count == 2)
    #expect(scans.allSatisfy { $0.interruption == .cancelled && !$0.isCleanable })
  }

  @Test func largeDirectoryDoesNotStopQueuedDirectories() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let small = try home.file("Library/Caches/small/data").deletingLastPathComponent()
    let (release, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    let large = CleanRule(
      id: "large", category: .system, title: "Fixture", detail: "", symbol: "archivebox"
    ) { _ in
      defer { continuation.finish() }
      let budget = try #require(ScanBudget.current)
      for _ in 0..<30 { try budget.visit() }
      return []
    }
    let waiting = CleanRule(
      id: "waiting", category: .developer, title: "Fixture", detail: "", symbol: "archivebox",
      requiredTool: "fixture",
      prepareTool: { _ in
        for await _ in release {}
        return ToolCachePlan(roots: [], tool: "fixture", arguments: [])
      })
    var environment = home.environment
    environment.isToolAvailable = { _ in true }
    environment.scanLimits = ScanLimits(maxEntries: 20, maxDuration: 20)
    let scans = await CleanEngine.scan(
      [
        large, waiting,
        rule(id: "small", urls: [small]), rule(id: "absent", urls: []),
      ], environment: environment)
    #expect(scans[0].isComplete)
    #expect(scans[0].items.isEmpty)
    #expect(scans[2].isComplete)
    #expect(scans[2].items.map(\.url) == [small])
    #expect(scans[3].isComplete)
  }

  @Test func previewOnlyRuleCannotDeleteEvenWhenExplicitlySelected() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let file = try home.file("Library/Caches/preview/data")
    let root = file.deletingLastPathComponent()
    let rule = CleanRule(
      id: "preview.fixture", category: .system, title: "Fixture", detail: "", symbol: "archivebox",
      previewOnly: true, minimumAge: 0
    ) { _ in [root] }
    let scans = await CleanEngine.scan([rule], environment: home.environment)
    let scan = try #require(scans.first)
    #expect(scan.items.count == 1)
    #expect(scan.isCleanable == false)
    #expect(scan.rule.selectedByDefault == false)
    let report = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: home.environment, log: nil)
    #expect(report.removedCount == 0)
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test func budgetDoesNotPublishAPartiallyMeasuredDirectory() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let root = try home.file("Library/Caches/big/a").deletingLastPathComponent()
    _ = try home.file("Library/Caches/big/b")
    _ = try home.file("Library/Caches/big/c")
    let rule = rule(urls: [root])
    var environment = home.environment
    environment.scanLimits = ScanLimits(maxEntries: 2, maxDuration: 20)
    let scan = await boundedScan(rule, environment: environment)
    #expect(scan.interruption == .entryLimit)
    #expect(scan.isComplete == false)
    #expect(scan.items.isEmpty)
    #expect(scan.unreadableCount == 0)
  }

  @Test func overlappingCandidatesAreMeasuredOnce() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let child = try home.file("Library/Caches/overlap/nested/data").deletingLastPathComponent()
    let parent = child.deletingLastPathComponent()
    let scan = try #require(
      await CleanEngine.scan([rule(urls: [child, parent, parent])], environment: home.environment)
        .first)
    #expect(scan.items.map(\.url) == [parent])
    #expect(scan.totalSize == CleanEngine.allocatedSize(of: parent))
  }

  @Test func sameCandidateAcrossRulesIsNotCountedTwice() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let root = try home.file("Library/Caches/shared/data").deletingLastPathComponent()
    let scans = await CleanEngine.scan(
      [rule(id: "first", urls: [root]), rule(id: "second", urls: [root])],
      environment: home.environment)
    #expect(scans.flatMap(\.items).count == 1)
    #expect(scans.reduce(UInt64(0)) { $0 + $1.totalSize } == CleanEngine.allocatedSize(of: root))
  }

  @Test func hardLinkedFilesAreMeasuredOnceWithinADirectory() throws {
    let home = try Fixture()
    defer { home.remove() }
    let file = try home.file("Library/Caches/linked/data")
    let alias = file.deletingLastPathComponent().appendingPathComponent("alias")
    try FileManager.default.linkItem(at: file, to: alias)
    #expect(
      try CleanEngine.scanAllocatedSize(of: file.deletingLastPathComponent())
        == CleanEngine.scanAllocatedSize(of: file))
  }

  @Test func blockedAndUnreadableResultsAreNotComplete() {
    let rule = rule(urls: [])
    #expect(
      RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .needsFullDiskAccess).isComplete
        == false)
    #expect(
      RuleScan(rule: rule, items: [], skippedCount: 0, blocked: nil, unreadableCount: 1).isComplete
        == false)
    #expect(RuleScan(rule: rule, items: [], skippedCount: 0, blocked: nil).isComplete)
  }

  @Test func locatingChildrenStopsAtTheSharedEntryLimit() async throws {
    let home = try Fixture()
    defer { home.remove() }
    for index in 0..<4 { _ = try home.file("Downloads/\(index).dmg") }
    var environment = home.environment
    environment.scanLimits = ScanLimits(maxEntries: 2, maxDuration: 20)
    let scan = await boundedScan(RuleCatalog.installers, environment: environment)
    #expect(scan.interruption == .entryLimit)
    #expect(!scan.isComplete && scan.items.isEmpty && scan.unreadableCount == 0)
  }

  @Test func discoveryAndMeasurementShareOneEntryBudget() async throws {
    let home = try Fixture()
    defer { home.remove() }
    _ = try home.file("Downloads/one.dmg")
    var environment = home.environment
    environment.scanLimits = ScanLimits(maxEntries: 1, maxDuration: 20)
    let scan = await boundedScan(RuleCatalog.installers, environment: environment)
    #expect(scan.interruption == .entryLimit)
    #expect(scan.items.isEmpty && !scan.isComplete)
  }

  @Test func swallowedDiscoveryLimitStillMarksTheRuleIncomplete() async throws {
    let home = try Fixture()
    defer { home.remove() }
    for index in 0..<3 { _ = try home.file("Downloads/\(index).dmg") }
    let rule = CleanRule(
      id: "swallowed", category: .downloads, title: "Fixture", detail: "", symbol: "archivebox",
      minimumAge: 0
    ) { environment in
      (try? RuleCatalog.childrenIfExists(of: environment.home + "/Downloads")) ?? []
    }
    var environment = home.environment
    environment.scanLimits = ScanLimits(maxEntries: 1, maxDuration: 20)
    let scan = await boundedScan(rule, environment: environment)
    #expect(scan.interruption == .entryLimit)
    #expect(!scan.isComplete && scan.items.isEmpty)
  }

  @Test func directChildrenDiscoveryHasABoundedDefault() throws {
    let home = try Fixture()
    defer { home.remove() }
    let directory = home.root.appendingPathComponent("discovery")
    for index in 0..<2_001 {
      try FileManager.default.createDirectory(
        at: directory.appendingPathComponent(String(index)), withIntermediateDirectories: true)
    }
    #expect(throws: ScanInterruption.entryLimit) {
      try RuleCatalog.childrenIfExists(of: directory.path)
    }
  }

  @Test func directDiscoveryCanShareTheCallersBudget() throws {
    let home = try Fixture()
    defer { home.remove() }
    _ = try home.file("Downloads/one")
    let budget = ScanBudget(limits: ScanLimits(maxEntries: 1, maxDuration: 20))
    #expect(
      try RuleCatalog.childrenIfExists(
        of: home.root.appendingPathComponent("Downloads").path,
        budget: budget
      ).count == 1)
    #expect(throws: ScanInterruption.entryLimit) { try budget.visit() }
    #expect(
      try RuleCatalog.childrenIfExists(of: home.root.appendingPathComponent("missing").path)
        .isEmpty)
    #expect(throws: (any Error).self) {
      try RuleCatalog.childrenIfExists(of: home.root.appendingPathComponent("Downloads/one").path)
    }
  }

  @Test func unsafeParentDoesNotHideASafeChild() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let child = try home.file("Library/Application Support/vendor/Cache/data")
      .deletingLastPathComponent()
    let parent = child.deletingLastPathComponent()
    let scan = try #require(
      await CleanEngine.scan([rule(urls: [parent, child])], environment: home.environment).first)
    #expect(scan.items.map(\.url) == [child])
    #expect(scan.skippedReasons[.protected] == 1)
  }

  @Test func candidatesAreStandardizedBeforeParentOrdering() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let child = try home.file("Library/Caches/normalized/!nested/data")
      .deletingLastPathComponent()
    let parent = child.deletingLastPathComponent()
    let dottedParent = URL(fileURLWithPath: parent.path + "/.")
    let scan = try #require(
      await CleanEngine.scan([rule(urls: [child, dottedParent])], environment: home.environment)
        .first)
    #expect(scan.items.map(\.url) == [parent])
    #expect(scan.totalSize == CleanEngine.allocatedSize(of: parent))
  }

  @Test func rulePriorityProtectsPreviewChildrenWithoutHidingSiblingPrefixes() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let child = try home.file("Library/Caches/tree/leaf/data").deletingLastPathComponent()
    let sibling = try home.file("Library/Caches/tree2/data").deletingLastPathComponent()
    let preview = CleanRule(
      id: "preview.child", category: .system, title: "Fixture", detail: "", symbol: "archivebox",
      previewOnly: true, minimumAge: 0
    ) { _ in [child] }
    let scans = await CleanEngine.scan(
      [rule(urls: [child.deletingLastPathComponent(), sibling]), preview],
      environment: home.environment)
    #expect(scans[0].items.map(\.url) == [sibling])
    #expect(scans[1].items.map(\.url) == [child])
    #expect(scans[0].skippedReasons[.protected] == 1)
  }

  @Test func directoryRulesCompleteWithoutTheSharedCandidateLimit() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let first = try home.file("Library/Caches/first/data").deletingLastPathComponent()
    let second = try home.file("Library/Caches/second/data").deletingLastPathComponent()
    var environment = home.environment
    environment.scanLimits = ScanLimits(maxEntries: 100, maxDuration: 20, maxCandidates: 1)
    let scans = await CleanEngine.scan(
      [
        rule(id: "first", urls: [first]), rule(id: "second", urls: [second]),
        rule(id: "queued", urls: [first]),
      ], environment: environment)
    #expect(scans.count == 3)
    #expect(scans.allSatisfy { $0.isComplete })
    #expect(Set(scans.flatMap(\.items).map(\.url)) == [first, second])
  }

  @Test func directoryScansIgnoreTheToolTimeLimit() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let root = try home.file("Library/Caches/fixture/data").deletingLastPathComponent()
    var environment = home.environment
    environment.scanLimits = ScanLimits(maxDuration: 0)
    let scans = await CleanEngine.scan(
      [rule(id: "cache", urls: [root])]
        + (0..<3).map { rule(id: String($0), urls: []) }, environment: environment)
    #expect(scans.count == 4)
    #expect(scans.allSatisfy { $0.isComplete })
    #expect(scans[0].items.map(\.url) == [root])
  }

  @Test func cancellationDuringLocateIsPreservedForAnEmptyResult() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let cancelled = CleanRule(
      id: "cancelled", category: .system, title: "Fixture", detail: "", symbol: "archivebox"
    ) { _ in
      withUnsafeCurrentTask { $0?.cancel() }
      return []
    }
    let scan = try #require(
      await CleanEngine.scan([cancelled], environment: home.environment).first)
    #expect(scan.interruption == .cancelled)
    #expect(!scan.isComplete && !scan.isCleanable)
  }

  @Test func toolTimeoutKeepsItsInterruptionMetadata() async throws {
    let home = try Fixture()
    defer { home.remove() }
    var environment = home.environment
    environment.isToolAvailable = { _ in true }
    let timedOut = CleanRule(
      id: "timeout", category: .developer, title: "Fixture", detail: "", symbol: "archivebox",
      requiredTool: "fixture", prepareTool: { _ in throw ToolExecutionError.timedOut("fixture") })
    let scan = try #require(await CleanEngine.scan([timedOut], environment: environment).first)
    #expect(scan.interruption == .timeLimit)
    #expect(!scan.isComplete && !scan.isCleanable)
    #expect(scan.unreadableCount == 0)
  }

  @Test func ordinaryFilesRemainCountedAlongsideHardLinks() throws {
    let home = try Fixture()
    defer { home.remove() }
    let file = try home.file("Library/Caches/mixed/data")
    let ordinary = try home.file("Library/Caches/mixed/ordinary")
    let directory = file.deletingLastPathComponent()
    try FileManager.default.linkItem(at: file, to: directory.appendingPathComponent("alias"))
    #expect(
      try CleanEngine.scanAllocatedSize(of: directory)
        == CleanEngine.scanAllocatedSize(of: file) + CleanEngine.scanAllocatedSize(of: ordinary))
  }

  @Test func genericOnlyScanCannotAcquirePreviewReservedPaths() async throws {
    let home = try Fixture()
    defer { home.remove() }
    _ = try home.file("Library/Caches/com.microsoft.teams2/data")
    let sibling = try home.file("Library/Caches/com.microsoft.teams2.other/data")
      .deletingLastPathComponent()
    var environment = home.environment
    environment.now = { Date.distantFuture }
    let scan = try #require(
      await CleanEngine.scan([RuleCatalog.userCaches], environment: environment).first)
    #expect(scan.isComplete)
    #expect(scan.items.map(\.url) == [sibling])
    #expect(scan.skippedReasons[.protected] == 1)
  }

  @Test func staleGenericScanCannotDeletePreviewReservedPaths() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let file = try home.file("Library/Caches/com.microsoft.teams2/data")
    let generic = RuleCatalog.userCaches
    let stale = RuleScan(
      rule: generic,
      items: [CleanItem(url: file.deletingLastPathComponent(), size: 4096)],
      skippedCount: 0, blocked: nil)
    var environment = home.environment
    environment.now = { Date.distantFuture }
    let report = await CleanEngine.clean(
      [stale], selected: [generic.id], preferTrash: false, environment: environment, log: nil)
    #expect(report.removedCount == 0)
    #expect(report.skippedCount == 1)
    #expect(try Data(contentsOf: file) == Data(repeating: 1, count: 4096))
  }

  @Test func interruptedToolCannotHandItsUnresolvedCacheToGenericCleanup() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let file = try home.file("Library/Caches/CustomUv/data")
    let cache = file.deletingLastPathComponent()
    let before = try Data(contentsOf: file)
    let interrupted = CleanRule(
      id: "interrupted", category: .developer, title: "Fixture", detail: "", symbol: "archivebox",
      requiredTool: "fixture", prepareTool: { _ in throw ScanInterruption.timeLimit })
    var environment = home.environment
    environment.now = { Date.distantFuture }
    environment.isToolAvailable = { _ in true }
    let scans = await CleanEngine.scan(
      [RuleCatalog.userCaches, interrupted], environment: environment)
    let generic = try #require(scans.first)
    let tool = try #require(scans.last)
    #expect(generic.items.map(\.url.path) == [cache.path])
    #expect(generic.totalSize > 0)
    #expect(generic.blocked != nil && !generic.isCleanable && !generic.isComplete)
    #expect(tool.toolCachePlan == nil && tool.interruption == .timeLimit)
    // UI 可能仅传选中的 generic；原清单的阻止原因必须足以拒绝执行。
    let report = await CleanEngine.clean(
      [generic], selected: [generic.id], preferTrash: false, environment: environment, log: nil)
    #expect(report.removedCount == 0)
    #expect(try Data(contentsOf: file) == before)
    // 旧清单未携带 blocked 时，执行入口也按随附的未知工具范围重新保护。
    let stale = RuleScan(
      rule: generic.rule, items: generic.items, skippedCount: 0, blocked: nil)
    let staleReport = await CleanEngine.clean(
      [stale, tool], selected: [generic.id], preferTrash: false, environment: environment, log: nil)
    #expect(staleReport.removedCount == 0)
    #expect(try Data(contentsOf: file) == before)
  }

  @Test func failedToolPreparationBlocksGenericWithoutDiscardingItsMeasurement() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let file = try home.file("Library/Caches/CustomUv/data")
    let failing = CleanRule(
      id: "failed", category: .developer, title: "Fixture", detail: "", symbol: "archivebox",
      requiredTool: "fixture",
      prepareTool: { _ in throw ToolCachePlanError.unknownScope })
    var environment = home.environment
    environment.now = { Date.distantFuture }
    environment.isToolAvailable = { _ in true }
    let scans = await CleanEngine.scan([RuleCatalog.userCaches, failing], environment: environment)
    let generic = try #require(scans.first)
    #expect(generic.items.count == 1 && generic.totalSize > 0)
    #expect(generic.blocked != nil && !generic.isCleanable)
    // 执行前工具消失不能把先前的未知自定义范围变成可直接删除的缓存。
    environment.isToolAvailable = { _ in false }
    let report = await CleanEngine.clean(
      scans, selected: [generic.id], preferTrash: false, environment: environment, log: nil)
    #expect(report.removedCount == 0)
    #expect(try Data(contentsOf: file) == Data(repeating: 1, count: 4096))
    let stale = RuleScan(
      rule: generic.rule, items: generic.items, skippedCount: 0, blocked: nil)
    let staleReport = await CleanEngine.clean(
      [stale] + Array(scans.dropFirst()), selected: [generic.id], preferTrash: false,
      environment: environment, log: nil)
    #expect(staleReport.removedCount == 0)
    #expect(try Data(contentsOf: file) == Data(repeating: 1, count: 4096))
  }

  @Test func unavailableToolsDoNotBlockUnrelatedGenericCachesAndLogs() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let cache = try home.file("Library/Caches/ordinary/data")
    let log = try home.file("Library/Logs/ordinary/data")
    var environment = home.environment
    environment.now = { Date.distantFuture }
    environment.isToolAvailable = { _ in false }
    environment.runTool = { _, _ in
      Issue.record("An unavailable tool must not execute")
      return ToolRunResult(status: 1, output: "")
    }
    environment.inspectTool = environment.runTool
    let tools = DeveloperCleanupCatalog.rules.filter { $0.usesToolCleaner }
    let scans = await CleanEngine.scan(
      [RuleCatalog.userCaches, RuleCatalog.logs] + tools, environment: environment)
    #expect(scans.prefix(2).allSatisfy { $0.isCleanable && $0.isComplete })
    #expect(
      scans.dropFirst(2).allSatisfy {
        $0.blocked == $0.rule.requiredTool.map { SkipReason.toolUnavailable($0) }
          && !$0.isCleanable
      })
    let report = await CleanEngine.clean(
      scans, selected: [RuleCatalog.userCaches.id, RuleCatalog.logs.id],
      preferTrash: false, environment: environment, log: nil)
    #expect(report.removedCount == 2 && report.failures.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: cache.path))
    #expect(!FileManager.default.fileExists(atPath: log.path))
  }

  @Test(arguments: ["Library/Caches/CustomCargo", "Library/Logs/CustomCargo"])
  func customCargoStorageStaysProtectedWithoutCargoCache(_ relativePath: String) async throws {
    let home = try Fixture()
    defer { home.remove() }
    let registry = try home.file(relativePath + "/registry/data")
    let git = try home.file(relativePath + "/git/data")
    let cargo = home.root.appendingPathComponent(relativePath)
    let parent = cargo.deletingLastPathComponent()
    let ordinary = try home.file(
      parent.lastPathComponent == "Caches"
        ? "Library/Caches/ordinary/data" : "Library/Logs/ordinary/data")
    let generic = parent.lastPathComponent == "Caches" ? RuleCatalog.userCaches : RuleCatalog.logs
    var environment = CleanEnvironment(
      home: home.root.path, runningBundleIdentifiers: { [] }, now: { Date.distantFuture },
      isToolAvailable: { _ in false },
      runTool: { _, _ in
        Issue.record("Missing cargo-cache must not invoke a tool")
        return ToolRunResult(status: 1, output: "")
      }, toolEnvironment: ["CARGO_HOME": cargo.path])
    environment.inspectTool = environment.runTool
    let roots = try DeveloperCleanupCatalog.rustStorageRoots(environment: environment)
    #expect(
      Set(roots.map(\.path))
        == Set([
          registry.deletingLastPathComponent().path, git.deletingLastPathComponent().path,
        ]))
    for rules in [[generic], [generic, DeveloperCleanupCatalog.rustCache]] {
      let scans = await CleanEngine.scan(rules, environment: environment)
      let scan = try #require(scans.first)
      #expect(scan.isCleanable && scan.isComplete)
      #expect(scan.items.map(\.url.path) == [ordinary.deletingLastPathComponent().path])
      #expect(scan.skippedReasons[.protected] == 1)
      if let tool = scans.dropFirst().first {
        #expect(tool.blocked == .toolUnavailable("cargo-cache"))
      }
    }
    let stale = RuleScan(
      rule: generic,
      items: [cargo, registry.deletingLastPathComponent(), git.deletingLastPathComponent()].map {
        CleanItem(url: $0, size: 4096)
      }, skippedCount: 0, blocked: nil)
    let report = await CleanEngine.clean(
      [stale], selected: [generic.id], preferTrash: false, environment: environment, log: nil)
    #expect(report.removedCount == 0 && report.skippedCount == 3)
    #expect(try Data(contentsOf: registry) == Data(repeating: 1, count: 4096))
    #expect(try Data(contentsOf: git) == Data(repeating: 1, count: 4096))
    #expect(FileManager.default.fileExists(atPath: ordinary.path))
  }

  @Test func directHardLinkCandidatesKeepFullIndividualSizesAndDeduplicateTheirTotal() async throws
  {
    let home = try Fixture()
    defer { home.remove() }
    let file = try home.file("Library/Caches/linked/data")
    let alias = file.deletingLastPathComponent().appendingPathComponent("alias")
    try FileManager.default.linkItem(at: file, to: alias)
    let size = try CleanEngine.scanAllocatedSize(of: file)
    let scan = try #require(
      await CleanEngine.scan([rule(urls: [file, alias])], environment: home.environment).first)
    #expect(scan.items.count == 2)
    #expect(scan.items.allSatisfy { $0.hardLinks.count == 1 })
    #expect(scan.items.allSatisfy { $0.size == size && CleanItem.totalSize(of: [$0]) == size })
    #expect(scan.totalSize == size)
    #expect(CleanItem.totalSize(of: scan.items) == size)
    #expect(CleanItem.totalSize(of: Array(scan.items.reversed())) == size)
  }

  @Test(arguments: [false, true])
  func hardLinksAcrossDirectoriesAndRulesUseTheSelectedUnion(_ separateRules: Bool) async throws {
    let home = try Fixture()
    defer { home.remove() }
    let file = try home.file("Library/Caches/left/shared")
    let leftOnly = try home.file("Library/Caches/left/ordinary")
    let rightOnly = try home.file("Library/Caches/right/ordinary")
    let left = file.deletingLastPathComponent()
    let right = rightOnly.deletingLastPathComponent()
    try FileManager.default.linkItem(at: file, to: right.appendingPathComponent("shared"))
    let rules =
      separateRules
      ? [rule(id: "left", urls: [left]), rule(id: "right", urls: [right])]
      : [rule(urls: [left, right])]
    let scans = await CleanEngine.scan(rules, environment: home.environment)
    let items = scans.flatMap(\.items)
    let sharedSize = try CleanEngine.scanAllocatedSize(of: file)
    let leftSize = try CleanEngine.scanAllocatedSize(of: leftOnly)
    let rightSize = try CleanEngine.scanAllocatedSize(of: rightOnly)
    #expect(items.count == 2)
    #expect(items.allSatisfy { $0.hardLinks.count == 1 })
    for item in items {
      let expected = sharedSize + (item.url.path == left.path ? leftSize : rightSize)
      #expect(item.size == expected)
      #expect(CleanItem.totalSize(of: [item]) == expected)
    }
    #expect(CleanItem.totalSize(of: items) == sharedSize + leftSize + rightSize)
    #expect(CleanItem.totalSize(of: Array(items.reversed())) == sharedSize + leftSize + rightSize)
    if !separateRules {
      #expect(scans.first?.totalSize == sharedSize + leftSize + rightSize)
    }
  }

  @Test func differingHardLinkObservationsHaveAnOrderIndependentTotal() {
    let items = [
      CleanItem(
        url: URL(fileURLWithPath: "/fixture/first"), size: 13,
        hardLinks: [.init(identity: "shared", size: 10)]),
      CleanItem(
        url: URL(fileURLWithPath: "/fixture/second"), size: 27,
        hardLinks: [.init(identity: "shared", size: 20), .init(identity: "other", size: 5)]),
      CleanItem(
        url: URL(fileURLWithPath: "/fixture/third"), size: 24,
        hardLinks: [.init(identity: "other", size: 7), .init(identity: "shared", size: 15)]),
    ]
    for item in items { #expect(CleanItem.totalSize(of: [item]) == item.size) }
    for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
      // 普通占用 3 + 2 + 2，加上各 inode 的最大观测 20 + 7。
      #expect(CleanItem.totalSize(of: order.map { items[$0] }) == 34)
    }
  }

  @Test(arguments: [false, true])
  func successfulManualCleanupReportsTheHardLinkUnionAcrossRules(_ useTrash: Bool) async throws {
    let home = try Fixture()
    defer { home.remove() }
    let file = try home.file("Library/Caches/left/shared")
    let leftOnly = try home.file("Library/Caches/left/ordinary")
    let rightOnly = try home.file("Library/Caches/right/ordinary")
    let left = file.deletingLastPathComponent()
    let right = rightOnly.deletingLastPathComponent()
    try FileManager.default.linkItem(at: file, to: right.appendingPathComponent("shared"))
    let expected =
      try CleanEngine.scanAllocatedSize(of: file)
      + CleanEngine.scanAllocatedSize(of: leftOnly) + CleanEngine.scanAllocatedSize(of: rightOnly)
    var environment = home.environment
    environment.trash = { url in
      try FileManager.default.moveItem(
        at: url, to: home.root.appendingPathComponent("trashed-\(url.lastPathComponent)"))
    }
    let scans = await CleanEngine.scan(
      [rule(id: "left", urls: [left]), rule(id: "right", urls: [right])],
      environment: environment)
    let report = await CleanEngine.clean(
      scans, selected: ["left", "right"], preferTrash: useTrash, environment: environment, log: nil)
    #expect(report.removedCount == 2 && report.failures.isEmpty)
    #expect(report.freedBytes == (useTrash ? 0 : expected))
    #expect(report.trashedBytes == (useTrash ? expected : 0))
  }

  @Test func manualCleanupCountsOnlySuccessfulCandidatesInItsHardLinkUnion() async throws {
    let home = try Fixture()
    defer { home.remove() }
    let file = try home.file("Library/Caches/linked/first")
    let alias = file.deletingLastPathComponent().appendingPathComponent("second")
    try FileManager.default.linkItem(at: file, to: alias)
    let failed = try home.file("Library/Caches/linked/failed")
    let skipped = try home.file("Library/Caches/linked/skipped")
    let size = try CleanEngine.scanAllocatedSize(of: file)
    var environment = home.environment
    environment.trash = { url in
      if url == failed { throw CocoaError(.fileWriteNoPermission) }
      try FileManager.default.moveItem(
        at: url, to: home.root.appendingPathComponent("trashed-\(url.lastPathComponent)"))
    }
    let scans = await CleanEngine.scan(
      [rule(urls: [file, alias, failed, skipped])], environment: environment)
    environment.excludedPaths = [skipped.path]
    let report = await CleanEngine.clean(
      scans, selected: ["fixture"], preferTrash: true, environment: environment, log: nil)
    #expect(report.removedCount == 2 && report.skippedCount == 1)
    #expect(report.failures.count == 1)
    #expect(report.trashedBytes == size && report.freedBytes == 0)
    #expect(FileManager.default.fileExists(atPath: failed.path))
    #expect(FileManager.default.fileExists(atPath: skipped.path))
  }

  @Test(arguments: [false, true])
  func permanentHardLinkCleanupIsUncertainWithARetainedOrFailedSibling(
    _ failedSibling: Bool
  ) async throws {
    let home = try Fixture()
    defer { home.remove() }
    let file = try home.file("Library/Caches/linked/a-selected")
    let alias = file.deletingLastPathComponent().appendingPathComponent("b-sibling")
    let outside = home.root.appendingPathComponent("outside-candidates")
    try FileManager.default.linkItem(at: file, to: alias)
    try FileManager.default.linkItem(at: file, to: outside)
    let environment = home.environment
    let scan = try #require(
      await CleanEngine.scan([rule(urls: [file, alias])], environment: environment).first)
    let size = try #require(scan.items.first).size
    let reviewed = RuleScan(
      rule: scan.rule,
      items: failedSibling ? scan.items : scan.items.filter { $0.url.path == file.path },
      skippedCount: 0, blocked: nil)
    // 模拟扫描后兄弟路径已消失；候选外仍保留同一 inode，删除不能证明块已释放。
    if failedSibling { try FileManager.default.removeItem(at: alias) }
    let report = await CleanEngine.clean(
      [reviewed], selected: [reviewed.id], preferTrash: false,
      environment: environment, log: nil)
    #expect(report.removedCount == 1)
    #expect(report.failures.count == (failedSibling ? 1 : 0))
    #expect(report.freedBytes == size && report.hasUncertainFreedBytes)
    #expect(try Data(contentsOf: outside) == Data(repeating: 1, count: 4096))
    #expect(FileManager.default.fileExists(atPath: alias.path) == !failedSibling)
  }

  @Test(arguments: [0, 1, 2])
  func toolWithoutAReportUsesTheBeforeAndAfterHardLinkUnion(_ removedRoots: Int) async throws {
    let home = try Fixture()
    defer { home.remove() }
    let file = try home.file("Library/Caches/left/shared")
    let leftOnly = try home.file("Library/Caches/left/ordinary")
    let rightOnly = try home.file("Library/Caches/right/ordinary")
    let roots = [file.deletingLastPathComponent(), rightOnly.deletingLastPathComponent()]
    let outside = home.root.appendingPathComponent("outside-candidates")
    try FileManager.default.linkItem(at: file, to: roots[1].appendingPathComponent("shared"))
    try FileManager.default.linkItem(at: file, to: outside)
    let leftSize = try CleanEngine.scanAllocatedSize(of: leftOnly)
    let tool = CleanRule(
      id: "tool.fixture", category: .developer, title: "Fixture", detail: "", symbol: "archivebox",
      requiredTool: "fixture",
      prepareTool: { _ in ToolCachePlan(roots: roots, tool: "fixture", arguments: ["clean"]) })
    var environment = home.environment
    environment.isToolAvailable = { _ in true }
    environment.runTool = { name, arguments in
      #expect(name == "fixture" && arguments == ["clean"])
      for root in roots.prefix(removedRoots) { try FileManager.default.removeItem(at: root) }
      return ToolRunResult(status: 0, output: "")
    }
    environment.inspectTool = { _, _ in
      Issue.record("Fixture preparation must not inspect real tools")
      return ToolRunResult(status: 1, output: "")
    }
    let scans = await CleanEngine.scan([tool], environment: environment)
    let before = CleanItem.totalSize(of: scans.flatMap(\.items))
    let report = await CleanEngine.clean(
      scans, selected: [tool.id], preferTrash: false, environment: environment, log: nil)
    let expected: UInt64 = removedRoots == 0 ? 0 : (removedRoots == 1 ? leftSize : before)
    #expect(report.freedBytes == expected)
    #expect(report.removedCount == removedRoots && report.failures.isEmpty)
    #expect(report.hasUncertainFreedBytes)
    #expect(try Data(contentsOf: outside) == Data(repeating: 1, count: 4096))
    for (index, root) in roots.enumerated() {
      #expect(FileManager.default.fileExists(atPath: root.path) == (index >= removedRoots))
    }
  }

  private actor EntryCounter {
    var counts: [Int] = []

    func record(_ count: Int) { counts.append(count) }
  }

  private actor ScanActivity {
    var active = 0
    var peak = 0

    func enter() {
      active += 1
      peak = max(peak, active)
    }

    func leave() { active -= 1 }
  }

  /// 同步目录定位闭包不能 await；仅用锁记录本次扫描实际消耗的读取额度。
  private final class VisitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var entries = 0

    func start() { lock.withLock { attempts += 1 } }
    func visit() { lock.withLock { entries += 1 } }
    func tick() -> Int {
      lock.withLock {
        attempts += 1
        return attempts
      }
    }
    var snapshot: [Int] { lock.withLock { [attempts, entries] } }
  }

  /// 有界检查仍须拒绝部分计量；清理生产入口不再使用此数量边界。
  private func boundedScan(_ rule: CleanRule, environment: CleanEnvironment) async -> RuleScan {
    await ScanBudget.$current.withValue(ScanBudget(limits: environment.scanLimits)) {
      await CleanEngine.scanRule(
        rule, environment: environment, safety: SafetyGuard(home: environment.home))
    }
  }

  private func rule(id: String = "fixture", urls: [URL]) -> CleanRule {
    CleanRule(
      id: id, category: .system, title: "Fixture", detail: "", symbol: "archivebox",
      minimumAge: 0
    ) { _ in urls }
  }

  private struct Fixture {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var environment: CleanEnvironment {
      var environment = CleanEnvironment(
        home: root.path, runningBundleIdentifiers: { [] }, toolEnvironment: [:])
      environment.activeProcessorCount = 4
      environment.scanLoad = { .init(cpuUsage: nil, memoryPressure: .normal) }
      return environment
    }

    func file(_ path: String) throws -> URL {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4096).write(to: url)
      return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
