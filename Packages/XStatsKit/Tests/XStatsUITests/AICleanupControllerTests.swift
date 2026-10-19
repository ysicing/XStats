// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
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
    controller.refresh()
    await gate.waitUntilStarted()
    controller.cancel()
    controller.refresh()
    for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.scan?.incomplete == true)
    await gate.release()
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.scan?.incomplete == true)
    #expect(!controller.isBusy)
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
