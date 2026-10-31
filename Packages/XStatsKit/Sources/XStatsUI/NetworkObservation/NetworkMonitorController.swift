// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import NetworkObservation
import Observation
import Updates

@MainActor @Observable final class NetworkMonitorController {
  enum Status: Equatable {
    case idle, starting, needsApproval, running, failed, restartRequired, preview
  }
  private(set) var status = Status.idle
  private(set) var error: String?
  private(set) var installationProgress: Double?
  private(set) var records: [ObservedConnection] = []
  private(set) var trafficHistory = NetworkTrafficHistory()
  private(set) var trafficAvailable = false
  let historyStore: NetworkHistoryStore
  var historyEnabled: Bool { status != .preview }
  private(set) var historyRevision = 0
  var previewCountries: [String: String] = [:]
  var previewLocations: [String: NetworkIPLocation] = [:]
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
  @ObservationIgnored private var historyOperation: Task<Void, Never>?
  @ObservationIgnored private var historyOperationID = UUID()
  @ObservationIgnored private var terminationPreparing = false
  @ObservationIgnored private var historySession = UUID()
  @ObservationIgnored private var historySessionStartedAt = Date()
  @ObservationIgnored private var historyDrainError: String?
  @ObservationIgnored private var historySessionActive = false
  @ObservationIgnored private var lastHistoryRefresh = Date.distantPast

  init(
    backend: any NetworkMonitorBackend = NativeNetworkMonitorBackend(),
    isSupported: Bool = NetworkMonitorSupport.isAvailable,
    defaults: UserDefaults = .standard,
    historyStore: NetworkHistoryStore = NetworkHistoryStore()
  ) {
    self.backend = backend
    self.isSupported = isSupported
    self.defaults = defaults
    self.historyStore = historyStore
    backend.onInstallationProgress = { [weak self] progress in
      guard let self else { return }
      if let progress, let previous = self.installationProgress, progress < 1,
        progress - previous < 0.01
      {
        return
      }
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
    if !enabled {
      records = []
      trafficHistory.clear()
    }
    if !enabled && (disabling || wantsRunning || status != .idle) {
      stop()
    } else {
      updateReading()
    }
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
    if historyDrainError != nil { beginHistoryDrain() }
    terminationPreparing = false
    reconcileConfiguration()
  }

  func stop() {
    guard isSupported else { return }
    wantsRunning = false
    persistAppUpdateIntent()
    installationProgress = nil
    backend.cancelActivation()
    beginHistoryDrain()
    records = []
    trafficHistory.clear()
    trafficAvailable = false
    activeConnectionIDs = []
    reconcileConfiguration()
  }

  /// 配置串行写入；启用途中关闭时先等系统回调，再保存关闭状态，避免晚到的 save 重新启用。
  private func reconcileConfiguration() {
    guard configurationTask == nil else { return }
    isBusy = true
    configurationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.configurationTask = nil
        self.isBusy = false
        self.updateReading()
      }
      while true {
        let enabling = self.wantsRunning
        do {
          await self.historyOperation?.value
          if enabling != self.wantsRunning { continue }
          if let historyDrainError = self.historyDrainError {
            self.status = .failed
            self.error = historyDrainError
            break
          }
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
          self.status = enabling ? .running : (self.historyDrainError == nil ? .idle : .failed)
          self.error = enabling ? nil : self.historyDrainError
          break
        } catch {
          if enabling != self.wantsRunning { continue }
          // 组件仍在等待用户批准系统扩展时客户端会先超时；保留授权提示，批准后由用户返回重试。
          if self.status == .needsApproval, (error as? NetworkMonitorError) == .timeout { break }
          self.status = .failed
          self.error = error.localizedDescription
          break
        }
      }
    }
  }

  private func updateReading() {
    let shouldRead =
      !terminationPreparing && historyOperation == nil && !componentUpdating && moduleEnabled
      && visible && !paused
      && !isManuallyPaused && wantsRunning
      && status == .running && !isBusy
    guard shouldRead else {
      if isReading || readTask != nil {
        beginHistoryDrain()
      }
      return
    }
    guard readTask == nil else { return }
    // 尾批失败后先重试原租约，成功落库前不能用新会话覆盖其状态。
    if historyDrainError != nil {
      beginHistoryDrain()
      return
    }
    readGeneration += 1
    let generation = readGeneration
    historySession = UUID()
    historySessionStartedAt = Date()
    historySessionActive = true
    isReading = true
    readTask = Task { [weak self] in
      guard let self else { return }
      var failures = 0
      while !Task.isCancelled {
        do {
          let batch = try await self.backend.read(after: self.cursor, epoch: self.epoch)
          guard !Task.isCancelled, self.readGeneration == generation else { return }
          // 游标是扩展的落库确认；写入失败/取消时不推进，重读由数据库幂等去重。
          try await self.historyStore.ingest(
            batch, session: self.historySession, sessionStartedAt: self.historySessionStartedAt)
          guard !Task.isCancelled, self.readGeneration == generation else { return }
          self.accept(batch)
          if batch.protocolVersion >= 3,
            batch.discarded > 0 || (batch.captureDropped ?? 0) > 0
          {
            self.error = tr("采集负载超过安全预算，历史可能不完整，请停止后重新开始")
            self.status = .failed
            self.backend.stopReading()
            self.isReading = false
            self.readTask = nil
            self.historyRevision &+= 1
            return
          }
          failures = 0
          let elapsed = Date().timeIntervalSince(self.lastHistoryRefresh)
          if (!batch.events.isEmpty && elapsed >= 1) || elapsed >= 15 {
            self.historyRevision &+= 1
            self.lastHistoryRefresh = Date()
          }
          // 满批立即续读；积压持续存在时仍按秒发布视图版本，不让界面长期冻结。
          if batch.events.count == ObservationLimits.batchCount { continue }
        } catch {
          guard !Task.isCancelled, self.readGeneration == generation else { return }
          self.trafficHistory.pause()
          self.backend.stopReading()
          self.historySession = UUID()
          self.historySessionStartedAt = Date()
          failures += 1
          if failures == 3 {
            self.status = .failed
            self.error = error.localizedDescription
            self.isReading = false
            self.readTask = nil
            return
          }
        }
        do { try await Task.sleep(for: .seconds(2), tolerance: .milliseconds(250)) } catch {
          return
        }
      }
    }
  }

  /// 先冻结采集并提交尾批，再停用过滤器；停止/退出不能直接清掉尚未 ACK 的队列。
  private func drainHistory() async throws {
    guard historySessionActive else { return }
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while let batch = try await backend.finishRead(after: cursor, epoch: epoch) {
      try await historyStore.ingest(
        batch, session: historySession, sessionStartedAt: historySessionStartedAt)
      accept(batch)
      // 丢失计数已随历史保存，不等于尾批写入失败；须允许停止过滤器以重置过载状态。
      if batch.events.count < ObservationLimits.batchCount { break }
      guard ContinuousClock.now < deadline else { throw NetworkMonitorError.timeout }
    }
    historySessionActive = false
    if error == historyDrainError { error = nil }
    historyDrainError = nil
    historyRevision &+= 1
  }

  private func beginHistoryDrain() {
    let reader = readTask
    stopReading(closeConnection: false)
    enqueueHistoryOperation {
      await reader?.value
      do {
        try await self.drainHistory()
      } catch {
        self.historyDrainError = error.localizedDescription
        self.error = error.localizedDescription
        self.isManuallyPaused = true
      }
      self.backend.stopReading()
    }
  }

  /// 清空、尾批和退出共享顺序；后来的动作不能被前一个 Task 的 defer 清掉。
  private func enqueueHistoryOperation(_ body: @escaping @MainActor () async -> Void) {
    let previous = historyOperation
    let id = UUID()
    historyOperationID = id
    historyOperation = Task {
      await previous?.value
      await body()
      guard historyOperationID == id else { return }
      historyOperation = nil
      updateReading()
    }
  }

  private func stopReading(closeConnection: Bool = true) {
    guard readTask != nil || isReading else { return }
    readGeneration += 1
    readTask?.cancel()
    readTask = nil
    isReading = false
    trafficHistory.pause()
    if closeConnection { backend.stopReading() }
  }

  func accept(_ batch: ObservationBatch) {
    if epoch != batch.epoch {
      epoch = batch.epoch
      trafficHistory.pause()
    }
    cursor = batch.cursor
    if !batch.events.isEmpty {
      // 关闭事件沿用连接标识；更新原记录，不把同一连接计数两次。
      let updates = Dictionary(
        batch.events.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      records = records.map { record in
        guard let update = updates[record.id], update.closedAt != record.closedAt else {
          return record
        }
        return update
      }
      let known = Set(records.map(\.id))
      records = Array(
        (records
          + updates.values.filter { !known.contains($0.id) }.sorted { $0.sequence < $1.sequence })
          .suffix(ObservationLimits.displayCount))
    }
    if batch.protocolVersion >= 3 {
      activeConnectionIDs = Set(records.filter { $0.closedAt == nil }.map(\.id))
    } else if let activeIDs = batch.activeIDs {
      activeConnectionIDs = Set(activeIDs)
    }
    trafficAvailable =
      batch.protocolVersion >= 3
      && batch.trafficVersion == NetworkObservationProtocol.trafficVersion
    if discarded != batch.discarded { discarded = batch.discarded }
  }

  func clearRecords() {
    stopReading()
    records = []
    activeConnectionIDs = []
    trafficHistory.clear()
    enqueueHistoryOperation {
      do {
        try await self.historyStore.clear()
        self.historyRevision &+= 1
      } catch {
        self.error = error.localizedDescription
      }
    }
  }

  func uninstall() {
    guard isSupported, !isBusy else { return }
    wantsRunning = false
    persistAppUpdateIntent()
    stopReading()
    isBusy = true
    configurationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isBusy = false
        self.configurationTask = nil
      }
      do {
        self.status = try await self.backend.uninstall() ? .restartRequired : .idle
        self.error = nil
        self.records = []
        self.trafficHistory.clear()
      } catch {
        self.status = .failed
        self.error = error.localizedDescription
      }
    }
  }

  /// 离屏走查只注入虚构元数据，不激活扩展或写系统网络设置。
  func showPreview(
    _ records: [ObservedConnection], trafficSnapshots: [ConnectionTrafficSnapshot] = []
  ) {
    self.records = Array(records.suffix(ObservationLimits.displayCount))
    trafficHistory.clear()
    trafficAvailable = !trafficSnapshots.isEmpty
    let metadata = Dictionary(
      self.records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    for snapshot in trafficSnapshots {
      if let record = metadata[snapshot.id] { trafficHistory.observe(record, snapshot: snapshot) }
    }
    activeConnectionIDs = Set(self.records.map(\.id))
    status = .preview
  }

  var terminationRequiresPreparation: Bool {
    isSupported
      && (wantsRunning || isBusy || isReading || terminationStopPending || historyOperation != nil)
  }
  func prepareForTermination(preserveFilter: Bool = false) async throws {
    guard isSupported, status != .preview else { return }
    terminationPreparing = true
    if !preserveFilter {
      wantsRunning = false
      terminationStopPending = true
    }
    backend.cancelActivation()
    let reader = readTask
    stopReading(closeConnection: false)
    enqueueHistoryOperation {
      await reader?.value
      do {
        try await self.drainHistory()
        self.backend.stopReading()
        if self.terminationPreparing { await self.historyStore.close() }
      } catch {
        self.historyDrainError = error.localizedDescription
        self.error = error.localizedDescription
      }
    }
    let pending = historyOperation
    await configurationTask?.value
    await pending?.value
    if let historyDrainError {
      throw NSError(
        domain: "NetworkHistory", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: historyDrainError
        ])
    }
    if !preserveFilter {
      try await backend.setFilterEnabled(false)
      status = .idle
      terminationStopPending = false
    }
  }
  /// 停用失败只拦截这一次退出；再次退出不再等待，避免应用无法退出。扩展观察租约到期后停止记录。
  func noteTerminationFailure(_ error: any Error) {
    self.error = error.localizedDescription
    status = .failed
    terminationStopPending = false
  }
  func beginComponentUpdate() {
    componentUpdating = true
    beginHistoryDrain()
  }

  func prepareComponentUpdate() async throws {
    beginComponentUpdate()
    await historyOperation?.value
    if let historyDrainError {
      throw NSError(
        domain: "NetworkHistory", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: historyDrainError
        ])
    }
  }
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
  func prepareForAppUpdate() {
    preparingAppUpdate = true
    persistAppUpdateIntent()
  }
  private func persistAppUpdateIntent() {
    guard preparingAppUpdate else { return }
    if wantsRunning {
      defaults.set(
        isManuallyPaused ? "paused" : "running", forKey: "networkMonitorResumeAfterUpdate")
    } else {
      defaults.removeObject(forKey: "networkMonitorResumeAfterUpdate")
    }
  }
  func cancelAppUpdate() {
    preparingAppUpdate = false
    terminationPreparing = false
    defaults.removeObject(forKey: "networkMonitorResumeAfterUpdate")
    updateReading()
  }
  func resumeAfterUpdate() {
    terminationPreparing = false
    let intent = defaults.string(forKey: "networkMonitorResumeAfterUpdate")
    defaults.removeObject(forKey: "networkMonitorResumeAfterUpdate")
    guard moduleEnabled, isSupported, intent == "running" || intent == "paused" else { return }
    wantsRunning = true
    isManuallyPaused = intent == "paused"
    reconcileConfiguration()
  }
}
