// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NetworkObservation
import Testing
import Updates
@testable import XStatsUI

@MainActor private final class ObservationBackendFixture: NetworkMonitorBackend {
    var onApproval: (() -> Void)?
    var onInstallationProgress: ((Double?) -> Void)?
    var onComponentStatus: ((NetworkComponentStatus) -> Void)?
    var filterWrites: [Bool] = []
    var stops = 0
    var readRequests = 0
    var holdEnable = false
    var disableError: (any Error)?
    var enableContinuation: CheckedContinuation<Void, Never>?
    var readContinuation: CheckedContinuation<ObservationBatch, any Error>?
    var holdShutdown = false
    var shutdownContinuation: CheckedContinuation<Void, Never>?
    var shutdownError: (any Error)?
    var activationError: (any Error)?
    func activate() async throws -> Bool {
        if let activationError { onApproval?(); throw activationError }
        return false
    }
    func cancelActivation() {}
    func setFilterEnabled(_ enabled: Bool) async throws {
        filterWrites.append(enabled)
        if !enabled, let disableError { throw disableError }
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
    @Test func rejectedQuitRestoresViewerAfterComponentHandoffWasCancelled() async throws {
        let backend = ObservationBackendFixture()
        let monitor = NetworkMonitorController(backend: backend, isSupported: true)
        let component = NetworkComponentController(backend: backend)
        component.onPreparingUpdate = { monitor.beginComponentUpdate() }
        component.onUpdateFinished = { monitor.finishComponentUpdate() }
        monitor.setDemand(enabled: true, visible: false)
        monitor.start()
        try await waitUntil { monitor.status == .running }
        var status = NetworkComponentStatus(componentVersion: "0.15.0", componentBuild: "138",
            extensionVersion: "0.15.0", extensionBuild: "138", observationMachService: "test",
            registration: .enabled, filterEnabled: true, update: .init(phase: .installing))
        backend.onComponentStatus?(status)
        await component.prepareForTermination()
        backend.disableError = NetworkMonitorError.timeout
        await #expect(throws: NetworkMonitorError.timeout) { try await monitor.prepareForTermination() }
        // 更新状态已收尾时必须解除暂停；仍在安装时则恢复有界验收。
        component.cancelTermination()
        #expect(component.terminationRequiresPreparation)
        status.update = .init(phase: .available)
        backend.onComponentStatus?(status)
        try await waitUntil { !component.terminationRequiresPreparation }
        backend.disableError = nil
        monitor.start()
        try await waitUntil { monitor.status == .running }
        monitor.shutdown()
    }
    @Test func mainUpdateOnlyStoresViewerIntentAndLeavesComponentRunning() async throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = ObservationBackendFixture()
        let controller = NetworkMonitorController(backend: backend, isSupported: true, defaults: defaults)
        controller.setDemand(enabled: true, visible: false)
        controller.start()
        try await waitUntil { controller.status == .running }
        controller.setObservationPaused(true)
        controller.prepareForAppUpdate()
        #expect(backend.filterWrites == [true])
        #expect(defaults.string(forKey: "networkMonitorResumeAfterUpdate") == "paused")
        let resumedBackend = ObservationBackendFixture()
        let resumed = NetworkMonitorController(backend: resumedBackend, isSupported: true, defaults: defaults)
        resumed.setDemand(enabled: true, visible: true)
        resumed.resumeAfterUpdate()
        try await waitUntil { resumed.status == .running }
        #expect(resumed.isManuallyPaused && !resumed.isReading)
        #expect(defaults.object(forKey: "networkMonitorResumeAfterUpdate") == nil)
        controller.cancelAppUpdate()
        #expect(backend.filterWrites == [true])
        controller.shutdown(); resumed.shutdown()
    }

    @Test func stopOrPauseDuringMainUpdateKeepsTheLatestViewerIntent() async throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = ObservationBackendFixture()
        let controller = NetworkMonitorController(backend: backend, isSupported: true, defaults: defaults)
        controller.setDemand(enabled: true, visible: false)
        controller.start()
        try await waitUntil { controller.status == .running }
        controller.prepareForAppUpdate()
        controller.setObservationPaused(true)
        #expect(defaults.string(forKey: "networkMonitorResumeAfterUpdate") == "paused")
        controller.stop()
        try await waitUntil { controller.status == .idle && !controller.isBusy }
        #expect(defaults.object(forKey: "networkMonitorResumeAfterUpdate") == nil)
        controller.start()
        try await waitUntil { controller.status == .running }
        #expect(defaults.string(forKey: "networkMonitorResumeAfterUpdate") == "running")
        controller.cancelAppUpdate()
        #expect(defaults.object(forKey: "networkMonitorResumeAfterUpdate") == nil)
        controller.shutdown()
    }

    @Test func failedQuitStopBlocksOnlyOnceSoTheNextQuitCanExit() async throws {
        let backend = ObservationBackendFixture()
        let controller = NetworkMonitorController(backend: backend, isSupported: true)
        controller.setDemand(enabled: true, visible: false)
        controller.start()
        try await waitUntil { controller.status == .running }
        backend.disableError = NetworkMonitorError.timeout
        await #expect(throws: NetworkMonitorError.timeout) { try await controller.prepareForTermination() }
        // 尚未上报失败前（例如主包更新路径）仍保留门禁，可以重试停用。
        #expect(controller.terminationRequiresPreparation)
        controller.noteTerminationFailure(NetworkMonitorError.timeout)
        #expect(controller.status == .failed && controller.error != nil)
        #expect(!controller.terminationRequiresPreparation, "上报失败后第二次退出必须直接放行")
    }

    @Test func approvalTimeoutKeepsApprovalPromptAndRetrySucceeds() async throws {
        let backend = ObservationBackendFixture()
        let controller = NetworkMonitorController(backend: backend, isSupported: true)
        controller.setDemand(enabled: true, visible: false)
        backend.activationError = NetworkMonitorError.timeout
        controller.start()
        try await waitUntil { !controller.isBusy }
        #expect(controller.status == .needsApproval, "等待批准时超时不应显示为失败")
        #expect(controller.error == nil)
        backend.activationError = nil
        controller.start()
        try await waitUntil { controller.status == .running }
        #expect(backend.filterWrites == [true])
        controller.shutdown()
    }
    @Test func mainPackageUpdateOnlyReleasesReaderWithoutDisablingComponent() async throws {
        let backend = ObservationBackendFixture()
        let controller = NetworkMonitorController(backend: backend, isSupported: true)
        controller.setDemand(enabled: true, visible: false)
        controller.start()
        try await waitUntil { controller.status == .running }
        try await controller.prepareForTermination(preserveFilter: true)
        #expect(backend.filterWrites == [true])
        controller.shutdown()
    }

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

    @Test func disablingAfterRelaunchTurnsOffPersistedFilterOnce() async throws {
        let backend = ObservationBackendFixture()
        // 重启后控制器为 idle，但上次会话启用的系统过滤配置仍然存在。
        let controller = NetworkMonitorController(backend: backend, isSupported: true)
        controller.setDemand(enabled: true, visible: false)
        #expect(controller.status == .idle && backend.filterWrites.isEmpty)
        controller.setDemand(enabled: false, visible: false)
        try await waitUntil { !controller.isBusy }
        #expect(backend.filterWrites == [false])
        // 模块保持关闭时的后续可见性变化不再重复写系统配置。
        controller.setDemand(enabled: false, visible: true)
        try await waitUntil { !controller.isBusy }
        #expect(backend.filterWrites == [false])
        #expect(controller.status == .idle)
    }

    @Test func fullBatchIsDrainedWithoutWaitingForNextPoll() async throws {
        let backend = ObservationBackendFixture()
        let controller = NetworkMonitorController(backend: backend, isSupported: true)
        controller.setDemand(enabled: true, visible: true)
        controller.start()
        try await waitUntil { backend.readContinuation != nil }
        let started = ContinuousClock.now
        backend.readContinuation?.resume(returning: batch(ObservationLimits.batchCount))
        backend.readContinuation = nil
        try await waitUntil { backend.readRequests == 2 }
        // 常规轮询间隔为 2 秒；读满后应立即续读积压事件。
        #expect(ContinuousClock.now - started < .milliseconds(1500))
        #expect(controller.records.count == ObservationLimits.batchCount)
        backend.readContinuation?.resume(throwing: CancellationError())
        backend.readContinuation = nil
        controller.stop()
        try await waitUntil { !controller.isBusy }
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

    @Test func crossApplicationRecordsAreNewestFirstInsteadOfAppNameOrder() {
        let original = batch().events[0]
        let start = Date(timeIntervalSince1970: 1_000)
        // 应用名 A 的连接更早、B 的更晚；按域名分组时不能先列出 A 的全部连接。
        let records = [("Alpha", 0.0), ("Beta", 1), ("Alpha", 2), ("Beta", 3)].map { name, offset in
            var record = original
            record.id = UUID(); record.timestamp = start.addingTimeInterval(offset)
            record.executablePath = "/Applications/\(name).app/Contents/MacOS/\(name)"
            return record
        }
        let matching = NetworkConnectionGroup.matching(records: records, query: "")
        #expect(matching.map(\.timestamp) == records.map(\.timestamp).reversed(), "跨应用记录应整体按时间倒序")
        #expect(NetworkConnectionGroup.matching(records: records, query: "Beta").map(\.id) == [records[3].id, records[1].id])
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

    @Test(.enabled(if: NetworkMonitorSupport.isAvailable))
    func unavailableXPCServiceReturnsErrorInsteadOfCrashingOffMainActor() async {
        let connection = NSXPCConnection(machServiceName: "work.12306.xstats.tests.missing.\(UUID().uuidString)")
        connection.remoteObjectInterface = NSXPCInterface(with: NetworkObservationService.self)
        connection.resume()
        let backend = NativeNetworkMonitorBackend(connection: connection)
        defer { backend.stopReading() }
        await #expect(throws: (any Error).self) { try await backend.read(after: 0, epoch: "") }
    }
}
