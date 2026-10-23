// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Testing
@testable import XStatsUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SystemCheckScopeTests {
  @Test func selectingScopesDoesNotStartChecksAndEachManualRequestKeepsItsContext() async throws {
    let recorder = Recorder()
    let controller = SystemCheckController { request in
      await recorder.record(request)
      return []
    }
    for scope in SystemCheckController.Scope.allCases { controller.selectScope(scope) }
    #expect(await recorder.requests.isEmpty)
    #expect(!controller.isChecking)
    #expect(controller.checkedAt == nil)

    for scope in SystemCheckController.Scope.allCases {
      controller.selectScope(scope)
      let task = try #require(
        controller.start(
          excludedPaths: ["/fixture/keep"], installedIdentifiers: ["com.example.installed"]))
      await task.value
      let request = try #require(await recorder.requests.last)
      #expect(request.scope == scope)
      #expect(request.excludedPaths == ["/fixture/keep"])
      #expect(request.installedIdentifiers == ["com.example.installed"])
      #expect(controller.checkedAt != nil)
    }
    #expect(await recorder.requests.count == SystemCheckController.Scope.allCases.count)
  }

  @Test func unloadedAppInventoryStaysUnknownRatherThanBecomingAnEmptyInventory() async throws {
    let recorder = Recorder()
    let controller = SystemCheckController { request in
      await recorder.record(request)
      return []
    }
    controller.selectScope(.storage)
    await controller.start()?.value
    #expect(try #require(await recorder.requests.first).installedIdentifiers == nil)
    await controller.start(installedIdentifiers: [])?.value
    #expect(try #require(await recorder.requests.last).installedIdentifiers == [])
  }

  @Test func changingScopeClearsEvidenceAndRejectsLateResults() async throws {
    let gate = Gate()
    let controller = SystemCheckController { request in
      await gate.collect(request.scope)
    }
    let old = try #require(controller.start())
    await gate.waitForStart()
    controller.selectScope(.network)
    #expect(!controller.isChecking)
    #expect(controller.findings.isEmpty)
    #expect(controller.checkedAt == nil)
    await gate.finish()
    await old.value
    #expect(controller.findings.isEmpty)

    let fresh = try #require(controller.start())
    await gate.waitForStart()
    await gate.finish()
    await fresh.value
    #expect(controller.findings.first?.id == "network")
    controller.selectScope(.storage)
    #expect(controller.findings.isEmpty)
    #expect(controller.checkedAt == nil)
  }

  private actor Recorder {
    var requests: [SystemCheckController.Request] = []
    func record(_ request: SystemCheckController.Request) { requests.append(request) }
  }

  private actor Gate {
    var scope: SystemCheckController.Scope?
    var completion: CheckedContinuation<[SystemCheckFinding], Never>?
    var start: CheckedContinuation<Void, Never>?

    func collect(_ scope: SystemCheckController.Scope) async -> [SystemCheckFinding] {
      self.scope = scope
      return await withCheckedContinuation {
        completion = $0
        start?.resume()
        start = nil
      }
    }

    func waitForStart() async {
      if completion != nil { return }
      await withCheckedContinuation { start = $0 }
    }

    func finish() {
      completion?.resume(returning: [
        SystemCheckFinding(
          id: scope?.rawValue ?? "unknown", title: "", status: .normal, detail: "")
      ])
      completion = nil
    }
  }
}
