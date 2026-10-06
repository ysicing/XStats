// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 只有 idle 才安排一次退出；RPC、Sparkle 周期和安装准备都持有活动计数，不后台轮询。
@MainActor final class ComponentServiceLifetime {
    private var calls = 0
    private var sdkActive = false
    private var preparationActive = false
    private var shutdownRequested = false
    private var generation = 0
    private var idleTask: Task<Void, Never>?
    private let sleep: @MainActor (Duration) async throws -> Void
    private let onIdle: @MainActor () -> Void

    init(sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         onIdle: @escaping @MainActor () -> Void) {
        self.sleep = sleep; self.onIdle = onIdle
    }
    func start() { scheduleIdleExit() }
    func beginRPC() { calls += 1; scheduleIdleExit() }
    func finishRPC() { precondition(calls > 0); calls -= 1; scheduleIdleExit() }
    func setSDKActive(_ value: Bool) { sdkActive = value; scheduleIdleExit() }
    func setPreparationActive(_ value: Bool) { preparationActive = value; scheduleIdleExit() }
    func requestShutdown() { shutdownRequested = true; scheduleIdleExit() }

    private func scheduleIdleExit() {
        generation += 1
        idleTask?.cancel(); idleTask = nil
        guard calls == 0, !sdkActive, !preparationActive else { return }
        let current = generation
        let delay: Duration = shutdownRequested ? .milliseconds(300) : .seconds(10)
        let sleep = sleep
        idleTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.generation == current,
                  self.calls == 0, !self.sdkActive, !self.preparationActive else { return }
            self.idleTask = nil
            self.onIdle()
        }
    }
}
