// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

@MainActor @Observable final class NetworkGeographyController {
    enum State: Equatable {
        case idle, downloading(Double), ready, failed
        var isDownloading: Bool { if case .downloading = self { return true }; return false }
    }
    private(set) var state = State.idle
    private(set) var hasData = false
    private(set) var revision = 0
    @ObservationIgnored private let service: OfflineGeography
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var demanded = false
    @ObservationIgnored private var generation = 0

    init(service: OfflineGeography = .shared) { self.service = service }

    func setDemand(enabled: Bool) {
        guard demanded != enabled else { return }
        demanded = enabled
        if enabled {
            // 失败后保留明确的重试入口，不因页面来回切换而连续请求。
            if state != .failed { start(force: false) }
        } else if task != nil {
            generation += 1
            task?.cancel(); task = nil
            state = hasData ? .ready : .idle
        }
    }

    func retry() { guard demanded, task == nil else { return }; start(force: true) }

    private func start(force: Bool) {
        guard task == nil else { return }
        generation += 1
        let current = generation
        state = .downloading(0)
        task = Task { [weak self] in
            guard let self else { return }
            let cached = await service.loadCached()
            guard !Task.isCancelled, generation == current else { return }
            if cached && !hasData { hasData = true; revision += 1 }
            do {
                _ = try await service.prepare(force: force) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current, self.task != nil else { return }
                        self.state = .downloading(min(1, max(0, progress)))
                    }
                }
                guard !Task.isCancelled, generation == current else { return }
                hasData = true; revision += 1; state = .ready; task = nil
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                state = .failed; task = nil
            }
        }
    }
}
