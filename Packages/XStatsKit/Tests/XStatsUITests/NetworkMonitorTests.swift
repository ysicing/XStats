// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NetworkObservation
import Testing
@testable import XStatsUI

@MainActor private final class ObservationBackendFixture: NetworkMonitorBackend {
    var onApproval: (() -> Void)?
    var filterWrites: [Bool] = []
    var stops = 0
    var readRequests = 0
    var holdEnable = false
    var enableContinuation: CheckedContinuation<Void, Never>?
    var readContinuation: CheckedContinuation<ObservationBatch, any Error>?
    func activate() async throws -> Bool { false }
    func cancelActivation() {}
    func setFilterEnabled(_ enabled: Bool) async throws {
        filterWrites.append(enabled)
        if enabled && holdEnable { await withCheckedContinuation { enableContinuation = $0 } }
    }
    func read(after cursor: Int64, epoch: String) async throws -> ObservationBatch {
        readRequests += 1
        return try await withCheckedThrowingContinuation { readContinuation = $0 }
    }
    func stopReading() { stops += 1 }
    func uninstall() async throws -> Bool { true }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor struct NetworkMonitorTests {
    @Test func onlyMacOS15AndLaterSupportConnectionViewing() {
        #expect(!NetworkMonitorSupport.supports(on: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0)))
        #expect(!NetworkMonitorSupport.supports(on: .init(majorVersion: 14, minorVersion: 9, patchVersion: 9)))
        #expect(NetworkMonitorSupport.supports(on: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
        #expect(NetworkMonitorSupport.supports(on: .init(majorVersion: 16, minorVersion: 0, patchVersion: 0)))
    }

    @Test func unsupportedSystemCannotStartOrConfigureTheExtension() async {
        let backend = ObservationBackendFixture()
        let controller = NetworkMonitorController(backend: backend, isSupported: false)
        controller.setDemand(enabled: true, visible: true)
        controller.start()
        controller.stop()
        controller.uninstall()
        await Task.yield()
        #expect(backend.filterWrites.isEmpty)
        #expect(backend.readContinuation == nil)
        #expect(controller.status == .idle && !controller.isBusy && !controller.isReading)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        while !predicate() {
            // 完整 UI 测试会长时间占用主 actor；等待调度进展，不把排队时间当作行为失败。
            // 套件时限负责检测真正不完成的操作，取消时必须退出等待。
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    private func batch(_ count: Int = 1) -> ObservationBatch {
        var journal = ConnectionJournal(capacity: max(1, count))
        for index in 0..<count {
            journal.append(ObservedConnection(id: UUID(), timestamp: Date(timeIntervalSince1970: Double(index)),
                processID: 42, executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
                address: "203.0.113.10", hostname: "example.invalid", port: 443, transport: .tcp, direction: .outbound))
        }
        return journal.batch(after: 0, epoch: "")
    }

    @Test func moduleDefaultsOffAndBackupContainsOnlyPreference() throws {
        let suite = "XStats.NetworkMonitorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.networkConnectionsEnabled)
        settings.panelTab = .connections
        #expect(settings.panelTab == .settingsFeatures)
        settings.networkConnectionsEnabled = true
        settings.panelTab = .connections
        #expect(settings.canViewNetworkConnections == NetworkMonitorSupport.isAvailable)
        #expect(AppSettings(defaults: defaults).panelTab == (NetworkMonitorSupport.isAvailable ? .connections : .settingsFeatures))
        #expect(settings.exportDocument().networkConnectionsEnabled == true)
        settings.networkConnectionsEnabled = false
        #expect(settings.panelTab == .settingsFeatures)
        #expect(AppDeepLink.page(.connections, settings: settings) == .settingsFeatures)
    }

    @Test func disablingDuringSaveCannotBeOverwrittenByLateEnable() async throws {
        let backend = ObservationBackendFixture()
        backend.holdEnable = true
        let controller = NetworkMonitorController(backend: backend, isSupported: true)
        controller.setDemand(enabled: true, visible: true)
        controller.start()
        try await waitUntil { backend.enableContinuation != nil }
        controller.setDemand(enabled: false, visible: false)
        backend.enableContinuation?.resume()
        backend.enableContinuation = nil
        try await waitUntil { !controller.isBusy }
        #expect(backend.filterWrites == [true, false])
        #expect(controller.status == .idle)
        #expect(!controller.isReading)
    }

    @Test func closingPageCancelsReadAndRejectsLateRecords() async throws {
        let backend = ObservationBackendFixture()
        let controller = NetworkMonitorController(backend: backend, isSupported: true)
        controller.setDemand(enabled: true, visible: true)
        controller.start()
        try await waitUntil { backend.readContinuation != nil }
        controller.setDemand(enabled: true, visible: false)
        let continuation = try #require(backend.readContinuation)
        backend.readContinuation = nil
        continuation.resume(returning: batch())
        await Task.yield()
        #expect(controller.records.isEmpty)
        #expect(!controller.isReading)
        #expect(backend.stops == 1)
        controller.stop()
        try await waitUntil { !controller.isBusy }
    }

    @Test func manualPauseKeepsRecordsAndCancelsInFlightRead() async throws {
        let backend = ObservationBackendFixture()
        let controller = NetworkMonitorController(backend: backend, isSupported: true)
        controller.setDemand(enabled: true, visible: true)
        controller.start()
        try await waitUntil { backend.readContinuation != nil }
        let observed = batch()
        controller.accept(observed)
        controller.setObservationPaused(true)
        #expect(controller.isManuallyPaused && !controller.isReading)
        #expect(controller.records == observed.events)
        #expect(backend.filterWrites == [true])
        backend.readContinuation?.resume(returning: batch())
        backend.readContinuation = nil
        controller.stop()
        try await waitUntil { !controller.isBusy }
    }

    @Test func manualResumeStartsOneNewReadWithoutReconfiguringFilter() async throws {
        let backend = ObservationBackendFixture()
        let controller = NetworkMonitorController(backend: backend, isSupported: true)
        controller.setDemand(enabled: true, visible: true)
        controller.start()
        try await waitUntil { backend.readRequests == 1 }
        let pending = try #require(backend.readContinuation)
        backend.readContinuation = nil
        controller.setObservationPaused(true)
        controller.setObservationPaused(false)
        try await waitUntil { backend.readRequests == 2 }
        #expect(controller.isReading && !controller.isManuallyPaused)
        #expect(backend.filterWrites == [true])
        pending.resume(throwing: CancellationError())
        backend.readContinuation?.resume(throwing: CancellationError())
        backend.readContinuation = nil
        controller.stop()
        try await waitUntil { !controller.isBusy }
    }

    @Test func openAndCloseInOneBatchHaveOneRowAndNoActiveConnection() {
        let buffer = ObservationBuffer()
        _ = buffer.read(after: 0, epoch: "", now: 1)
        let record = batch().events[0]
        buffer.record(record, now: 2)
        buffer.close(record.id)
        let controller = NetworkMonitorController(backend: ObservationBackendFixture(), isSupported: true)
        controller.accept(buffer.read(after: 0, epoch: "", now: 3))
        #expect(controller.records.count == 1)
        #expect(controller.records.first?.closedAt != nil)
        #expect(controller.activeConnectionIDs.isEmpty)
    }

    @Test func reconnectKeepsPreviouslyObservedHistory() {
        let controller = NetworkMonitorController(backend: ObservationBackendFixture(), isSupported: true)
        let first = batch()
        let second = batch()
        #expect(first.epoch != second.epoch)
        controller.accept(first)
        controller.accept(second)
        #expect(controller.records.map(\.id) == (first.events + second.events).map(\.id))
    }

    @Test func oldExtensionWithoutActiveSnapshotCannotSilentlyProduceAnEmptyActiveView() throws {
        let legacy = batch()
        #expect(legacy.activeIDs == nil)
        #expect(throws: (any Error).self) {
            try NativeNetworkMonitorBackend.decodeBatch(JSONEncoder().encode(legacy))
        }
        var current = legacy
        current.activeIDs = []
        #expect(try NativeNetworkMonitorBackend.decodeBatch(JSONEncoder().encode(current)) == current)
    }

    @Test func removalReportsPendingRebootInsteadOfSuccess() async throws {
        let controller = NetworkMonitorController(backend: ObservationBackendFixture(), isSupported: true)
        controller.uninstall()
        try await waitUntil { !controller.isBusy }
        #expect(controller.status == .restartRequired)
    }

    @Test func overviewIncludesEveryMatchingGroupAndSingleSelectionStillFilters() throws {
        var first = batch().events[0]
        first.executablePath = "/Applications/First.app/Contents/MacOS/First"
        var second = first
        second.id = UUID(); second.executablePath = "/Applications/Second.app/Contents/MacOS/Second"
        let groups = NetworkConnectionGroup.make(records: [first, second], query: "")
        let overview = try #require(NetworkConnectionGroup.selected(in: groups, id: nil))
        #expect(overview.id == NetworkConnectionGroup.allIdentifier)
        #expect(Set(overview.records.map(\.id)) == [first.id, second.id])
        let single = try #require(NetworkConnectionGroup.selected(in: groups, id: groups[0].id))
        #expect(single.records.count == 1)
        let filtered = NetworkConnectionGroup.make(records: [first, second], query: "Second")
        #expect(NetworkConnectionGroup.selected(in: filtered, id: nil)?.records.map(\.id) == [second.id])
        #expect(NetworkConnectionGroup.selected(in: filtered, id: "missing")?.id == NetworkConnectionGroup.allIdentifier)
    }

    @Test func sameNamedApplicationCopiesKeepStableOrderingAcrossRefreshes() {
        let original = batch().events[0]
        let paths = ["/Applications/Z/Browser.app/Contents/MacOS/Browser", "/Applications/A/Browser.app/Contents/MacOS/Browser", "/Applications/M/Browser.app/Contents/MacOS/Browser"]
        let records = paths.map { path in
            var record = original; record.id = UUID(); record.executablePath = path; return record
        }
        for _ in 0..<20 {
            let groups = NetworkConnectionGroup.make(records: records, query: "")
            #expect(groups.map(\.id) == groups.map(\.id).sorted())
        }
    }

    @Test func displayRemainsBoundedAndGroupsProcessesByApp() {
        let controller = NetworkMonitorController(backend: ObservationBackendFixture(), isSupported: true)
        var events = batch().events
        let original = events[0]
        for index in 1..<1000 {
            var event = original
            event.id = UUID(); event.processID = Int32(index); event.sequence = Int64(index + 1)
            events.append(event)
        }
        controller.showPreview(events)
        #expect(controller.records.count == ObservationLimits.displayCount)
        let groups = NetworkConnectionGroup.make(records: controller.records, query: "example.invalid")
        #expect(groups.count == 1)
        #expect(groups[0].records.count == ObservationLimits.displayCount)
        #expect(NetworkConnectionGroup.make(records: controller.records, query: "missing.invalid").isEmpty)
    }

    @Test func cancellationBeforeXPCRegistrationCompletesExactlyOnce() async throws {
        let reply = NetworkMonitorReply()
        reply.finish(.failure(CancellationError()))
        await #expect(throws: CancellationError.self) {
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                reply.finish(.success(Data([1])))
            }
        }
    }
}
