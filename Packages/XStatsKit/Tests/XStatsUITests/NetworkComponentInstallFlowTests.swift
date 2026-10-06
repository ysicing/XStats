// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import NetworkObservation
import Testing
@testable import XStatsUI

@MainActor private final class InstallFlowBackend: NetworkMonitorBackend {
    var onApproval: (() -> Void)?
    var onInstallationProgress: ((Double?) -> Void)?
    var onComponentStatus: ((NetworkComponentStatus) -> Void)?
    var continuation: CheckedContinuation<NetworkComponentResponse, any Error>?
    var cancellations = 0
    var commands: [String] = []
    func activate() async throws -> Bool { false }
    func cancelActivation() { cancellations += 1 }
    func setFilterEnabled(_ enabled: Bool) async throws {}
    func read(after cursor: Int64, epoch: String) async throws -> ObservationBatch { throw CancellationError() }
    func stopReading() {}
    func uninstall() async throws -> Bool { false }
    func componentCommand(_ command: String) async throws -> NetworkComponentResponse {
        commands.append(command)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<NetworkComponentResponse, any Error>) {
        let pending = continuation; continuation = nil; pending?.resume(with: result)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct NetworkComponentInstallFlowTests {
    private var ready: NetworkComponentResponse {
        .init(status: .init(componentVersion: "0.15.0", componentBuild: "138", extensionVersion: "0.15.0", extensionBuild: "138",
                            observationMachService: "test", registration: .enabled, filterEnabled: false))
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
    @Test func successfulInstallContinuesEnableOnlyAfterReadyReply() async throws {
        let backend = InstallFlowBackend()
        let installed = NetworkComponentController(backend: backend)
        var enabled = false
        installed.install { enabled = true }
        try await waitUntil { backend.continuation != nil }
        #expect(!enabled && !installed.installed && installed.busy)
        backend.finish(.success(ready))
        try await waitUntil { !installed.busy }
        #expect(enabled && installed.installed)
        #expect(backend.commands == ["status"])
    }
    @Test func failedInstallDoesNotContinueEnable() async throws {
        let backend = InstallFlowBackend()
        let installed = NetworkComponentController(backend: backend)
        var enabled = false
        installed.install { enabled = true }
        try await waitUntil { backend.continuation != nil }
        backend.finish(.failure(URLError(.badServerResponse)))
        try await waitUntil { !installed.busy }
        #expect(!enabled && !installed.installed && installed.error != nil)
    }
    @Test func quittingDuringInstallRejectsLateEnableCompletion() async throws {
        let backend = InstallFlowBackend(), component = NetworkComponentController(backend: backend)
        var enabled = false
        component.install { enabled = true }
        try await waitUntil { backend.continuation != nil }
        let terminating = Task { await component.prepareForTermination() }
        try await waitUntil { backend.cancellations > 0 }
        backend.finish(.success(ready))
        await terminating.value
        #expect(!enabled && !component.installed && !component.busy)
    }
}
