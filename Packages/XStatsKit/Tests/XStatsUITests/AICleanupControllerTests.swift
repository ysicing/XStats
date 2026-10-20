// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import Cleaner
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct AICleanupControllerTests {
  @Test func cancelledScanCannotPublishIntoNewerScan() async throws {
    let first = AICleanupScan()
    var result = AICleanupScan()
    result.incomplete = true
    let latest = result
    let gate = AICleanupScanGate()
    let controller = AICleanupController(scanner: { _ in
      await gate.next(first: first, latest: latest)
    })
    controller.loadIfNeeded(excludedPaths: [])
    await gate.waitUntilStarted()
    controller.cancel()
    controller.loadIfNeeded(excludedPaths: [])
    for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.scan?.incomplete == true)
    await gate.release()
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.scan?.incomplete == true)
    #expect(!controller.isBusy)
  }

  @Test func reopeningReusesEvenIncompleteResultUntilExplicitRefresh() async throws {
    let recorder = AICleanupScanRecorder()
    let controller = AICleanupController(scanner: { try await recorder.scan($0) })
    controller.loadIfNeeded(excludedPaths: [])
    for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.scan?.incomplete == true)
    for _ in 0..<3 {
      controller.cancel()
      controller.loadIfNeeded(excludedPaths: [])
      #expect(!controller.isBusy)
    }
    #expect(await recorder.environments.count == 1)

    controller.refresh()
    for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await recorder.environments.count == 2)
    #expect(controller.scan?.incomplete == false)
    controller.invalidate()
    #expect(controller.scan == nil)
    controller.loadIfNeeded(excludedPaths: [])
    for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await recorder.environments.count == 3)
  }

  @Test func changingExclusionsInvalidatesProtectionAndPreservesScanRoots() async throws {
    let recorder = AICleanupScanRecorder()
    let controller = AICleanupController(scanner: { try await recorder.scan($0) })
    controller.loadIfNeeded(excludedPaths: ["/tmp/kept-a", "/tmp/kept-b"])
    for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    let roots = try #require(controller.scan).searchedRoots
    controller.loadIfNeeded(excludedPaths: ["/tmp/kept-b", "/tmp/kept-a"])
    #expect(!controller.isBusy)
    #expect(await recorder.environments.count == 1)

    controller.loadIfNeeded(excludedPaths: ["/tmp/kept-c"])
    #expect(controller.scan == nil)
    for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    let environments = await recorder.environments
    #expect(environments.count == 2)
    #expect(environments.last?.clean.excludedPaths == ["/tmp/kept-c"])
    #expect(environments.last?.searchRoots == roots)
  }

  @Test func failedManualRefreshKeepsLastSnapshotWithoutRetryingOnReopen() async throws {
    let recorder = AICleanupScanRecorder(failAfterFirst: true)
    let controller = AICleanupController(scanner: { try await recorder.scan($0) })
    controller.loadIfNeeded(excludedPaths: [])
    for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    controller.refresh()
    for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.isError)
    #expect(controller.scan?.incomplete == true)
    controller.cancel()
    controller.loadIfNeeded(excludedPaths: [])
    #expect(!controller.isBusy)
    #expect(await recorder.environments.count == 2)
  }

  @Test func cancelledRemovalCannotReuseSnapshotFromBeforeOperation() async throws {
    let recorder = AICleanupScanRecorder()
    let controller = AICleanupController(scanner: { try await recorder.scan($0) })
    controller.loadIfNeeded(excludedPaths: [])
    for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    let roots = try #require(controller.scan).searchedRoots
    let missing = URL(fileURLWithPath: "/nonexistent/xstats-test-worktree")
    controller.confirmation = .worktree(
      AIWorktree(
        url: missing, repository: missing, branch: "test", head: "", bytes: nil,
        protection: nil, identity: nil, gitIdentity: nil, commonIdentity: nil))
    controller.confirm()
    // 不让移除任务运行；仅验证取消时必须舍弃可能已过期的盘点。
    controller.cancel()
    #expect(controller.scan == nil)
    #expect(controller.confirmation == nil)
    controller.loadIfNeeded(excludedPaths: [])
    for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await recorder.environments.count == 2)
    #expect(await recorder.environments.last?.searchRoots == roots)
  }

  @Test func cancelledConfirmationIsInvalidatedAndScanFailureDoesNotInventEmptyResult() async throws
  {
    let controller = AICleanupController(scanner: { _ in throw CocoaError(.fileReadNoPermission) })
    controller.refresh()
    for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.scan == nil)
    #expect(controller.isError)
    #expect(controller.message != nil)
    controller.cancel()
    #expect(controller.confirmation == nil)
    #expect(!controller.isBusy)
  }
}

private actor AICleanupScanRecorder {
  var environments: [AICleanupEnvironment] = []
  let failAfterFirst: Bool

  init(failAfterFirst: Bool = false) {
    self.failAfterFirst = failAfterFirst
  }

  func scan(_ environment: AICleanupEnvironment) throws -> AICleanupScan {
    environments.append(environment)
    if failAfterFirst, environments.count > 1 { throw CocoaError(.fileReadNoPermission) }
    var result = AICleanupScan()
    result.incomplete = environments.count == 1
    result.searchedRoots = environment.searchRoots ?? [URL(fileURLWithPath: "/tmp/agent-projects")]
    return result
  }
}

private actor AICleanupScanGate {
  var count = 0
  var continuation: CheckedContinuation<Void, Never>?
  func next(first: AICleanupScan, latest: AICleanupScan) async -> AICleanupScan {
    count += 1
    if count > 1 { return latest }
    await withCheckedContinuation { continuation = $0 }
    return first
  }
  func waitUntilStarted() async {
    while continuation == nil { await Task.yield() }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
