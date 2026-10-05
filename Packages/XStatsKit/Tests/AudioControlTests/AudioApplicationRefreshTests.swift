// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import AudioControl

private final class ApplicationActivityFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var playing: UInt32 = 0
    private var readCalls = 0
    private var notifications = 0
    func read() -> [UInt32] { lock.withLock { readCalls += 1; return [1,42,playing] } }
    func resume() { lock.withLock { playing = 1 } }
    func notify() { lock.withLock { notifications += 1 } }
    var reads: Int { lock.withLock { readCalls } }
    var events: Int { lock.withLock { notifications } }
}

struct AudioApplicationRefreshTests {
    @Test func missedPlaybackNotificationsAreDetectedAndCheckingStopsWithoutApplicationDemand() async throws {
        let fixture = ApplicationActivityFixture()
        let client = AudioHardwareClient(selectDevice: { _, _, _ in nil }, applicationActivity: { fixture.read() })
        client.watch(applications: true, applicationRefreshInterval: 0.05) { fixture.notify() }
        _ = await client.listenerCount() // 串行屏障，等待监听初始化。
        let deadline = ContinuousClock.now + .seconds(20)
        while fixture.reads < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fixture.reads >= 3, "没有 HAL 通知时，也必须定期检查播放标记")
        let before = fixture.events
        fixture.resume()
        let changedDeadline = ContinuousClock.now + .seconds(20)
        while fixture.events == before, ContinuousClock.now < changedDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fixture.events > before)
        client.watch(applications: false) { fixture.notify() }
        _ = await client.listenerCount()
        let readsAfterClosing = fixture.reads
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.reads == readsAfterClosing)
        client.stopWatching()
        #expect(await client.listenerCount() == 0)
    }
}
