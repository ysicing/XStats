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
    @ObservationIgnored private var epoch = ""
    @ObservationIgnored private var cursor: Int64 = 0
    @ObservationIgnored private var preparingUpdate = false
    @ObservationIgnored private var updatePreparationTask: Task<Void, any Error>?
    @ObservationIgnored private var resumeRunningAfterUpdate = false
    @ObservationIgnored private var resumePausedAfterUpdate = false
    @ObservationIgnored private var suppressUpdateResume = false
    private static let resumeKey = "networkMonitorResumeAfterUpdate"

    init(backend: any NetworkMonitorBackend = NativeNetworkMonitorBackend(), isSupported: Bool = NetworkMonitorSupport.isAvailable,
         defaults: UserDefaults = .standard) {
        self.backend = backend
        self.isSupported = isSupported
        self.defaults = defaults
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
        updateReading()
    }

    func start() {
        guard moduleEnabled, !isBusy, !preparingUpdate else { return }
        wantsRunning = true
        isManuallyPaused = false
        error = nil
        reconcileConfiguration()
    }

    func stop() {
        guard isSupported else { return }
        if preparingUpdate {
            suppressUpdateResume = true
            defaults.removeObject(forKey: Self.resumeKey)
            return
        }
        wantsRunning = false
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
            defer { self.configurationTask = nil; self.isBusy = self.preparingUpdate; self.updateReading() }
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
        let shouldRead = moduleEnabled && visible && !paused && !isManuallyPaused && wantsRunning && status == .running && !isBusy && !preparingUpdate
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
        guard isSupported, !isBusy, !preparingUpdate else { return }
        wantsRunning = false
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

    func shutdown() {
        wantsRunning = false
        backend.cancelActivation()
        stopReading()
    }

    /// 安装前串行等待已有配置写入，再停用过滤器；成功后保持门禁到退出或取消安装。
    func prepareForUpdate(target: UpdateRelease.NetworkExtension) async throws {
        if let updatePreparationTask {
            try await updatePreparationTask.value
            try Task.checkCancellation()
            return
        }
        guard isSupported, status != .preview else { return }
        preparingUpdate = true
        suppressUpdateResume = false
        resumeRunningAfterUpdate = wantsRunning
        resumePausedAfterUpdate = isManuallyPaused
        isBusy = true
        backend.cancelActivation()
        stopReading(closeConnection: false)
        let task = Task {
            await configurationTask?.value
            wantsRunning = false
            let wasEnabled = try await backend.prepareForUpdate(target: target)
            resumeRunningAfterUpdate = moduleEnabled && !suppressUpdateResume && (resumeRunningAfterUpdate || wasEnabled)
            // 只有确实停用后才保存重启标记，取消或崩溃前的准备不能伪装成停止完成。
            if resumeRunningAfterUpdate {
                defaults.set(resumePausedAfterUpdate ? "paused" : "running", forKey: Self.resumeKey)
            } else { defaults.removeObject(forKey: Self.resumeKey) }
            status = .idle
            error = nil
        }
        updatePreparationTask = task
        do {
            try await task.value
            try Task.checkCancellation()
        } catch {
            cancelUpdatePreparation()
            throw error
        }
    }

    func cancelUpdatePreparation() {
        guard preparingUpdate else { return }
        preparingUpdate = false
        updatePreparationTask = nil
        isBusy = false
        defaults.removeObject(forKey: Self.resumeKey)
        wantsRunning = resumeRunningAfterUpdate && moduleEnabled && !suppressUpdateResume
        isManuallyPaused = resumePausedAfterUpdate
        reconcileConfiguration()
    }

    /// 一次性更新意图不进入设置备份或连接历史；只有已启用模块才能恢复。
    func resumeAfterUpdate() {
        let intent = defaults.string(forKey: Self.resumeKey)
        defaults.removeObject(forKey: Self.resumeKey)
        guard moduleEnabled, isSupported, intent == "running" || intent == "paused" else { return }
        wantsRunning = true
        isManuallyPaused = intent == "paused"
        reconcileConfiguration()
    }
}
