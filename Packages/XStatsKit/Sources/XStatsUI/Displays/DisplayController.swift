// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Observation

/// 显示器信息由系统事件刷新；仅控制界面可见时读取 DDC，不将滑杆值自动恢复到硬件。
@MainActor
@Observable
final class DisplayController {
    private(set) var catalog: [DisplayInfo]
    private(set) var readings: [UInt32: [DisplayControl: DDCResult]] = [:]
    private(set) var isRefreshing = false
    private(set) var isWriting = false
    private(set) var isPaused = false
    private var settlingUntil: ContinuousClock.Instant?
    var isSettling: Bool { settlingUntil != nil }
    @ObservationIgnored private let backend: any DisplayDDCBackend
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cancellation: DDCCancellation?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var editingTokens: Set<UUID> = []
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    init(backend: any DisplayDDCBackend = NativeDisplayDDC(), catalog: [DisplayInfo] = []) {
        self.backend = backend
        self.catalog = catalog
    }

    func start() {
        guard screenObserver == nil else { return }
        refreshCatalog()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenConfigurationChanged() }
            }
    }

    func stop() {
        visible = false
        invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    func refreshCatalog() {
        let updated = DisplayInfo.all()
        let connectionsChanged = catalog.map(\.target) != updated.map(\.target)
        if connectionsChanged {
            invalidate()
            readings = [:]
        }
        if updated != catalog { catalog = updated }
        if connectionsChanged && visible && !isPaused {
            deferCommunication(for: .seconds(1))
            restart()
        }
    }

    private func screenConfigurationChanged() {
        invalidate()
        backend.resetConnections()
        readings = [:]
        refreshCatalog()
        deferCommunication(for: .seconds(1))
        restart()
    }

    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        invalidate()
        restart()
    }

    func setPaused(_ value: Bool) {
        guard isPaused != value else { return }
        isPaused = value
        invalidate()
        if !value {
            backend.resetConnections()
            refreshCatalog()
            // 唤醒后让显示链路先稳定，期间不发送 DDC 报文。
            deferCommunication(for: .seconds(3))
            restart()
        }
    }

    private func invalidate() {
        generation = UUID()
        loop?.cancel()
        loop = nil
        cancellation?.cancel()
        cancellation = nil
        isRefreshing = false
        isWriting = false
        editingTokens.removeAll()
    }

    private func deferCommunication(for delay: Duration) {
        let deadline = ContinuousClock.now.advanced(by: delay)
        settlingUntil = max(settlingUntil ?? deadline, deadline)
    }

    private func restart() {
        loop?.cancel()
        loop = nil
        guard visible, !isPaused else { return }
        let epoch = generation
        let deadline = settlingUntil
        loop = Task { [weak self] in
            if let deadline {
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            }
            guard !Task.isCancelled, self?.generation == epoch else { return }
            self?.settlingUntil = nil
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(5), tolerance: .seconds(1)) } catch { return }
            }
        }
    }

    func beginEditing(_ token: UUID) { editingTokens.insert(token) }
    func endEditing(_ token: UUID) { editingTokens.remove(token) }

    func refresh() async {
        guard visible, !isPaused, !isSettling, !Task.isCancelled, !isRefreshing, !isWriting, editingTokens.isEmpty else { return }
        let epoch = generation
        isRefreshing = true
        defer { if generation == epoch { isRefreshing = false; cancellation = nil } }
        var updated: [UInt32: [DisplayControl: DDCResult]] = [:]
        for display in catalog where !display.isBuiltIn {
            // 超时会取消本台的令牌；每台独立，避免一台无响应导致后面的显示器跳过读取。
            let ticket = DDCCancellation()
            cancellation = ticket
            let result = await withTaskCancellationHandler {
                await backend.read(display.target, cancellation: ticket)
            } onCancel: { ticket.cancel() }
            guard generation == epoch, !Task.isCancelled else { return }
            updated[display.id] = result
        }
        guard generation == epoch else { return }
        readings = updated
        isRefreshing = false
        cancellation = nil
    }

    /// 手动重新检测：丢弃已缓存的服务匹配（含未找到），再读取一次。
    func redetect() async {
        backend.resetConnections()
        await refresh()
    }

    func write(_ percent: Double, control: DisplayControl, display: DisplayInfo) async {
        guard visible, !isPaused, !isSettling, !Task.isCancelled, !isRefreshing, !isWriting,
              catalog.contains(where: { $0.target == display.target }),
              case .value = readings[display.id]?[control], percent.isFinite, (0...100).contains(percent) else { return }
        let epoch = generation
        let ticket = DDCCancellation()
        cancellation = ticket
        isWriting = true
        defer { if generation == epoch { isWriting = false; cancellation = nil } }
        let result = await withTaskCancellationHandler {
            await backend.write(display.target, control: control, percent: percent, cancellation: ticket)
        } onCancel: { ticket.cancel() }
        guard generation == epoch, !Task.isCancelled else { return }
        readings[display.id, default: [:]][control] = result
        isWriting = false
        cancellation = nil
    }
}
