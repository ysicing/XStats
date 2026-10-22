// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner
@testable import XStatsUI

@MainActor
struct HomebrewServicesControllerTests {
  @Test func hiddenAndPausedPagesDoNotReadAndLateResultsAreDiscarded() async throws {
    let gate = BrewServiceReadGate()
    let controller = HomebrewServicesController(
      brewAvailable: { true }, readInventory: { await gate.read() })
    controller.refresh()
    #expect(await gate.calls == 0)
    controller.setVisible(true)
    await waitUntil { await gate.calls == 1 }
    controller.setVisible(false)
    try await gate.finish()
    for _ in 0..<10 { await Task.yield() }
    #expect(controller.services.isEmpty && !controller.isLoading)
    controller.setPaused(true)
    controller.setVisible(true)
    #expect(!controller.isLoading)
    controller.setPaused(false)
    await waitUntil { await gate.calls == 2 }
    try await gate.finish()
    await waitUntil { !controller.isLoading }
    #expect(controller.services.count == 1)
    controller.setVisible(false)
    controller.refresh()
    #expect(await gate.calls == 2)
  }

  @Test func errorsStayVisibleAndRefreshCanRecover() async throws {
    let fixture = BrewServiceFailureFixture()
    let controller = HomebrewServicesController(
      brewAvailable: { true }, readInventory: { try await fixture.read() })
    controller.setVisible(true)
    await waitUntil { !controller.isLoading }
    #expect(controller.error != nil && controller.services.isEmpty)
    controller.refresh()
    await waitUntil { !controller.isLoading }
    #expect(controller.error == nil && controller.services.count == 1)
    controller.setVisible(false)
  }

  @Test func operationsAreSerializedAndDoNotRefreshHiddenPages() async throws {
    let gate = BrewServiceReadGate()
    let fixture = BrewServiceOperationFixture()
    let controller = HomebrewServicesController(
      brewAvailable: { true }, readInventory: { await gate.read() },
      performAction: { action, _ in await fixture.perform(action) })
    controller.setVisible(true)
    await waitUntil { await gate.calls == 1 }
    try await gate.finish()
    await waitUntil { !controller.isLoading }
    let service = try #require(controller.services.first)
    controller.perform(.start, service: service)
    controller.perform(.restart, service: service)
    await waitUntil { await fixture.calls == 1 }
    controller.setVisible(false)
    await fixture.finish()
    await waitUntil { controller.working == nil }
    #expect(controller.completion != nil)
    #expect(await gate.calls == 1)
    #expect(await fixture.calls == 1)
    let completion = try #require(controller.completion)
    controller.dismissCompletion("unrelated")
    #expect(controller.completion == completion)
    controller.dismissCompletion(completion)
    #expect(controller.completion == nil)
  }

  @Test func absentHomebrewDoesNotStartARead() async {
    let gate = BrewServiceReadGate()
    let controller = HomebrewServicesController(
      brewAvailable: { false }, readInventory: { await gate.read() })
    controller.setVisible(true)
    controller.refresh()
    #expect(!controller.isLoading)
    #expect(await gate.calls == 0)
  }

  @Test func serviceSearchDoesNotSearchLaunchdItems() throws {
    let services = try HomebrewServices.parse(
      #"[{"name":"redis","status":"started","user":"alice"},{"name":"postgresql@17","status":"none"}]"#
    )
    #expect(
      HomebrewServicesPage.filteredServices(services, search: "REDIS").map(\.name) == ["redis"])
    #expect(HomebrewServicesPage.filteredServices(services, search: "alice").count == 1)
    #expect(HomebrewServicesPage.filteredServices(services, search: "com.apple").isEmpty)
  }

  @Test func availabilityIsRecheckedOnOpeningAndRefreshing() async throws {
    var available = false
    let gate = BrewServiceReadGate()
    let controller = HomebrewServicesController(
      brewAvailable: { available }, readInventory: { await gate.read() })
    controller.setVisible(true)
    #expect(!controller.brewAvailable && !controller.isLoading)
    #expect(await gate.calls == 0)

    available = true
    controller.refresh()
    await waitUntil { await gate.calls == 1 }
    try await gate.finish()
    await waitUntil { !controller.isLoading }
    #expect(controller.brewAvailable && controller.services.count == 1)

    controller.setVisible(false)
    available = false
    controller.setVisible(true)
    #expect(!controller.brewAvailable && controller.services.isEmpty)
    #expect(controller.error == nil)
    #expect(await gate.calls == 1)

    controller.setVisible(false)
    available = true
    controller.setVisible(true)
    await waitUntil { await gate.calls == 2 }
    try await gate.finish()
    await waitUntil { !controller.isLoading }
    #expect(controller.brewAvailable && controller.services.count == 1)
    controller.setVisible(false)
  }

  @Test(arguments: [
    ("started", HomebrewServices.Action.stop),
    ("scheduled", .stop),
    ("error", .restart),
    ("stopped", .start),
    ("none", .start),
    ("unknown", .start),
  ])
  func primaryActionMatchesServiceState(
    status: String, expected: HomebrewServices.Action
  ) throws {
    let services = try HomebrewServices.parse(
      #"[{"name":"redis","status":"\#(status)"}]"#)
    let service = try #require(services.first)
    #expect(HomebrewServicesPage.primaryAction(service) == expected)
  }

  private func waitUntil(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
    #expect(await condition())
  }
}

private actor BrewServiceReadGate {
  private(set) var calls = 0
  private var pending: CheckedContinuation<[HomebrewService], Never>?

  func read() async -> [HomebrewService] {
    calls += 1
    return await withCheckedContinuation { pending = $0 }
  }

  func finish() throws {
    pending?.resume(returning: try HomebrewServices.parse(#"[{"name":"redis","status":"none"}]"#))
    pending = nil
  }
}

private actor BrewServiceFailureFixture {
  private var calls = 0
  func read() throws -> [HomebrewService] {
    calls += 1
    if calls == 1 { throw HomebrewServices.ServiceError.invalidOutput }
    return try HomebrewServices.parse(#"[{"name":"redis","status":"started"}]"#)
  }
}

private actor BrewServiceOperationFixture {
  private(set) var calls = 0
  private var pending: CheckedContinuation<Void, Never>?
  func perform(_ action: HomebrewServices.Action) async {
    calls += 1
    await withCheckedContinuation { pending = $0 }
  }
  func finish() {
    pending?.resume()
    pending = nil
  }
}
