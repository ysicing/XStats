// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NetworkObservation
import Observation
import Updates

@MainActor @Observable final class NetworkMonitorController {
    enum Status: Equatable { case idle, starting, needsApproval, running, failed, restartRequired, preview }
    private(set) var status = Status.idle
    private(set) var error: String?
    private(set) var installationProgress: Double?
    private(set) var records: [ObservedConnection] = []
    var previewCountries: [String: String] = [:]
    var previewWorld: [NetworkCountry] = []
    private(set) var activeConnectionIDs: Set<UUID> = []
    private(set) var discarded: Int64 = 0
    private(set) var isReading = false
    private(set) var isManuallyPaused = false
    private(set) var isBusy = false
    @ObservationIgnored private let backend: any NetworkMonitorBackend
    @ObservationIgnored private let isSupported: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var configurationTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var moduleEnabled = false
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var preparingAppUpdate = false
    @ObservationIgnored private var componentUpdating = false
    @ObservationIgnored private var terminationStopPending = false
    @ObservationIgnored private var epoch = ""
    @ObservationIgnored private var cursor: Int64 = 0

    init(backend: any NetworkMonitorBackend = NativeNetworkMonitorBackend(), isSupported: Bool = NetworkMonitorSupport.isAvailable,
         defaults: UserDefaults = .standard) {
        self.backend = backend
        self.isSupported = isSupported
        self.defaults = defaults
        backend.onInstallationProgress = { [weak self] progress in
            guard let self else { return }
            if let progress, let previous = self.installationProgress, progress < 1, progress - previous < 0.01 { return }
            self.installationProgress = progress
        }
        backend.onApproval = { [weak self] in self?.status = .needsApproval }
    }

    func setDemand(enabled: Bool, visible: Bool) {
        let enabled = enabled && isSupported
        // 系统过滤配置跨进程保留；重启后控制器为 idle，关闭模块时仍须写入停用。
        let disabling = moduleEnabled && !enabled
        moduleEnabled = enabled
        self.visible = visible
        if !enabled && !records.isEmpty { records = [] }
        if !enabled && (disabling || wantsRunning || status != .idle) { stop() }
        else { updateReading() }
    }

    func setPaused(_ value: Bool) {
        paused = value
        updateReading()
    }

    func setObservationPaused(_ value: Bool) {
        isManuallyPaused = value
        persistAppUpdateIntent()
        updateReading()
    }

    func start() {
        guard moduleEnabled, !isBusy, !componentUpdating else { return }
        wantsRunning = true
        isManuallyPaused = false
        persistAppUpdateIntent()
        error = nil
        reconcileConfiguration()
    }

    func stop() {
        guard isSupported else { return }
        wantsRunning = false
        persistAppUpdateIntent()
        installationProgress = nil
        backend.cancelActivation()
        stopReading()
        records = []
        activeConnectionIDs = []
        reconcileConfiguration()
    }

    /// 配置串行写入；启用途中关闭时先等系统回调，再保存关闭状态，避免晚到的 save 重新启用。
    private func reconcileConfiguration() {
        guard configurationTask == nil else { return }
        isBusy = true
        configurationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.configurationTask = nil; self.isBusy = false; self.updateReading() }
            while true {
                let enabling = self.wantsRunning
                do {
                    if enabling {
                        self.status = .starting
                        let needsRestart = try await self.backend.activate()
                        if !self.wantsRunning { continue }
                        if needsRestart {
                            self.wantsRunning = false
                            self.status = .restartRequired
                            break
                        }
                    }
                    try await self.backend.setFilterEnabled(enabling)
                    if enabling != self.wantsRunning { continue }
                    self.status = enabling ? .running : .idle
                    self.error = nil
                    break
                } catch {
                    if enabling != self.wantsRunning { continue }
                    self.status = .failed
                    self.error = error.localizedDescription
                    break
                }
            }
        }
    }

    private func updateReading() {
        let shouldRead = !componentUpdating && moduleEnabled && visible && !paused && !isManuallyPaused && wantsRunning && status == .running && !isBusy
        guard shouldRead else { stopReading(); return }
        guard readTask == nil else { return }
        readGeneration += 1
        let generation = readGeneration
        isReading = true
        readTask = Task { [weak self] in
            guard let self else { return }
            var failures = 0
            while !Task.isCancelled {
                do {
                    let batch = try await self.backend.read(after: self.cursor, epoch: self.epoch)
                    guard !Task.isCancelled, self.readGeneration == generation else { return }
                    self.accept(batch)
                    failures = 0
                    // 批次读满说明还有积压；立即续读，避免突发连接在环形缓冲中被覆盖。
                    if batch.events.count == ObservationLimits.batchCount { continue }
                } catch {
                    guard !Task.isCancelled, self.readGeneration == generation else { return }
                    self.backend.stopReading()
                    failures += 1
                    if failures == 3 {
                        self.status = .failed
                        self.error = error.localizedDescription
                        self.isReading = false
                        self.readTask = nil
                        return
                    }
                }
                do { try await Task.sleep(for: .seconds(2), tolerance: .milliseconds(250)) }
                catch { return }
            }
        }
    }

    private func stopReading(closeConnection: Bool = true) {
        guard readTask != nil || isReading else { return }
        readGeneration += 1
        readTask?.cancel()
        readTask = nil
        isReading = false
        if closeConnection { backend.stopReading() }
    }

    func accept(_ batch: ObservationBatch) {
        if epoch != batch.epoch { epoch = batch.epoch }
        cursor = batch.cursor
        if !batch.events.isEmpty {
            // 关闭事件沿用连接标识；更新原记录，不把同一连接计数两次。
            let updates = Dictionary(batch.events.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            records = records.map { updates[$0.id] ?? $0 }
            let known = Set(records.map(\.id))
            records = Array((records + updates.values.filter { !known.contains($0.id) }.sorted { $0.sequence < $1.sequence }).suffix(ObservationLimits.displayCount))
        }
        if let activeIDs = batch.activeIDs { activeConnectionIDs = Set(activeIDs) }
        if discarded != batch.discarded { discarded = batch.discarded }
    }

    func clearRecords() { records = []; activeConnectionIDs = [] }

    func uninstall() {
        guard isSupported, !isBusy else { return }
        wantsRunning = false
        persistAppUpdateIntent()
        stopReading()
        isBusy = true
        configurationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.configurationTask = nil }
            do {
                self.status = try await self.backend.uninstall() ? .restartRequired : .idle
                self.error = nil
                self.records = []
            } catch { self.status = .failed; self.error = error.localizedDescription }
        }
    }

    /// 离屏走查只注入虚构元数据，不激活扩展或写系统网络设置。
    func showPreview(_ records: [ObservedConnection]) {
        self.records = Array(records.suffix(ObservationLimits.displayCount))
        activeConnectionIDs = Set(self.records.map(\.id))
        status = .preview
    }

    var terminationRequiresPreparation: Bool { isSupported && (wantsRunning || isBusy || isReading || terminationStopPending) }
    func prepareForTermination(preserveFilter: Bool = false) async throws {
        guard isSupported, status != .preview else { return }
        if !preserveFilter { wantsRunning = false; terminationStopPending = true }
        backend.cancelActivation()
        stopReading()
        await configurationTask?.value
        if !preserveFilter { try await backend.setFilterEnabled(false); status = .idle; terminationStopPending = false }
    }
    func noteTerminationFailure(_ error: any Error) { self.error = error.localizedDescription; status = .failed }
    func beginComponentUpdate() { componentUpdating = true; stopReading() }
    func finishComponentUpdate() {
        componentUpdating = false
        if wantsRunning { reconcileConfiguration() } else { updateReading() }
    }

    func shutdown() {
        wantsRunning = false
        backend.cancelActivation()
        stopReading()
    }

    /// 主包更新只保存界面观察意图，不调用组件的过滤器管理接口。
    func prepareForAppUpdate() { preparingAppUpdate = true; persistAppUpdateIntent() }
    private func persistAppUpdateIntent() {
        guard preparingAppUpdate else { return }
        if wantsRunning { defaults.set(isManuallyPaused ? "paused" : "running", forKey: "networkMonitorResumeAfterUpdate") }
        else { defaults.removeObject(forKey: "networkMonitorResumeAfterUpdate") }
    }
    func cancelAppUpdate() { preparingAppUpdate = false; defaults.removeObject(forKey: "networkMonitorResumeAfterUpdate") }
    func resumeAfterUpdate() {
        let intent = defaults.string(forKey: "networkMonitorResumeAfterUpdate")
        defaults.removeObject(forKey: "networkMonitorResumeAfterUpdate")
        guard moduleEnabled, isSupported, intent == "running" || intent == "paused" else { return }
        wantsRunning = true
        isManuallyPaused = intent == "paused"
        reconcileConfiguration()
    }
}
