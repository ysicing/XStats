// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Metrics
import Observation
import os

/// 仅能耗详情可见且功能启用时读取；关闭、锁屏及休眠后取消并清除结果。
@MainActor
@Observable
final class SleepAssertionController {
    private(set) var processes: [SleepBlockingProcess]?
    private(set) var isUnavailable = false
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let read: @Sendable () async throws -> [SleepBlockingProcess]
    private static let logger = Logger(subsystem: Log.subsystem, category: "sleep-assertions")

    init(read: @escaping @Sendable () async throws -> [SleepBlockingProcess] = {
        try await Task.detached(priority: .utility) { try SleepAssertionReader.read() }.value
    }) {
        self.read = read
    }

    deinit { task?.cancel() }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        update()
    }

    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        update()
    }

    private func update() {
        if task != nil { Self.logger.debug("停止读取睡眠阻止信息") }
        task?.cancel()
        task = nil
        processes = nil
        isUnavailable = false
        guard visible && !paused else { return }
        Self.logger.debug("开始按需读取睡眠阻止信息")
        let read = read
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let processes = try await read()
                    // 系统调用无法中断；关闭或重新打开后，旧任务不得发布结果。
                    guard !Task.isCancelled, let self else { return }
                    if self.isUnavailable { Self.logger.notice("睡眠阻止信息读取已恢复") }
                    self.isUnavailable = false
                    if self.processes != processes { self.processes = processes }
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    if !self.isUnavailable {
                        let code = (error as? SleepAssertionReader.ReadError)?.code ?? -1
                        Self.logger.error("无法读取睡眠阻止信息，状态码 \(code)")
                    }
                    self.processes = nil
                    self.isUnavailable = true
                }
                do { try await Task.sleep(for: .seconds(10), tolerance: .seconds(2)) }
                catch { return }
            }
        }
    }
}
