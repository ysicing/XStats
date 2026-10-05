// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 只在正在处理的音频上检查帧计数；同一配置失败两次后停止自动重建。
struct AudioRenderHealth {
    enum Action: Equatable { case wait, retry, release }
    private var frames: UInt64
    private var observedAt: Double
    private(set) var failures = 0
    init(frames: UInt64 = 0, now: Double) { self.frames = frames; observedAt = now }
    mutating func observe(frames: UInt64, now: Double) -> Action {
        if frames != self.frames { self.frames = frames; observedAt = now; failures = 0; return .wait }
        guard now - observedAt >= 1.5 else { return .wait }
        failures += 1
        observedAt = now
        return failures == 1 ? .retry : .release
    }
    mutating func restarted(frames: UInt64 = 0, now: Double) { self.frames = frames; observedAt = now }
}
