// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AudioControl

/// 应用暂停后短时保留处理管线，恢复播放时不会先以原音量漏出；到期后释放空闲 tap。
struct AudioPlaybackGrace {
    static let duration = Duration.seconds(60)
    private var playing: Set<String> = []
    private var pausedAt: [String: ContinuousClock.Instant] = [:]

    func contains(_ id: String) -> Bool { playing.contains(id) || pausedAt[id] != nil }

    /// 返回最早的到期时间；没有处于宽限期的暂停应用时为 nil。
    mutating func update(_ applications: [AudioApplication], now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        let present = Set(applications.map(\.id))
        let currentlyPlaying = Set(applications.filter(\.isPlaying).map(\.id))
        // 播放期间未必有 HAL 刷新；宽限期必须从首次观察到暂停开始，后续暂停快照不续期。
        for id in playing.subtracting(currentlyPlaying).intersection(present) { pausedAt[id] = now }
        playing = currentlyPlaying
        pausedAt = pausedAt.filter { present.contains($0.key) && !playing.contains($0.key) && now - $0.value < Self.duration }
        return pausedAt.values.min().map { $0 + Self.duration }
    }

    mutating func reset() { playing.removeAll(); pausedAt.removeAll() }
}

/// 重建会创建私有聚合设备并触发 HAL 刷新；相同请求只记为待复核，不打断仍在等待首帧的管线。
struct AudioMixRequestTracker {
    struct Request: Equatable {
        let targets: [AudioMixTarget]
        let outputUID: String?
    }
    private var running: (generation: UInt64, request: Request)?
    private var generation: UInt64 = 0
    private var needsRecheck = false

    /// 返回 nil 表示与进行中的请求相同，结束后再核对一次。
    mutating func begin(_ request: Request) -> UInt64? {
        if running?.request == request { needsRecheck = true; return nil }
        generation &+= 1
        running = (generation, request)
        needsRecheck = false
        return generation
    }

    /// 返回进行中期间是否收到过相同请求；过期的完成事件不影响新请求。
    mutating func finish(_ generation: UInt64) -> Bool {
        guard running?.generation == generation else { return false }
        running = nil
        defer { needsRecheck = false }
        return needsRecheck
    }

    mutating func reset() { running = nil; needsRecheck = false }
}
