// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
@testable import AudioControl
@testable import XStatsUI

struct AudioPlaybackGraceTests {
    private func app(_ id: String, playing: Bool) -> AudioApplication {
        AudioApplication(id: id, name: id, processObjectIDs: [1], isPlaying: playing)
    }

    @Test func pausedAppStaysEligibleUntilTheGraceExpires() {
        var grace = AudioPlaybackGrace()
        let start = ContinuousClock.now
        let playingExpiry = grace.update([app("a", playing: true)], now: start)
        #expect(playingExpiry == nil, "播放中的应用不需要到期唤醒")
        let expiry = grace.update([app("a", playing: false)], now: start + .seconds(10))
        #expect(expiry == start + AudioPlaybackGrace.duration, "到期时间从最后一次播放算起，而不是暂停被发现的时间")
        #expect(grace.contains("a"))
        let expiredExpiry = grace.update([app("a", playing: false)], now: start + AudioPlaybackGrace.duration)
        #expect(expiredExpiry == nil)
        #expect(!grace.contains("a"), "宽限期结束后应释放空闲 tap")
    }

    @Test func resumingPlaybackRestartsTheGrace() {
        var grace = AudioPlaybackGrace()
        let start = ContinuousClock.now
        _ = grace.update([app("a", playing: true)], now: start)
        _ = grace.update([app("a", playing: true)], now: start + .seconds(50))
        let expiry = grace.update([app("a", playing: false)], now: start + .seconds(55))
        #expect(expiry == start + .seconds(50) + AudioPlaybackGrace.duration)
        #expect(grace.contains("a"))
    }

    @Test func neverPlayedOrExitedAppsAreNotRetained() {
        var grace = AudioPlaybackGrace()
        let start = ContinuousClock.now
        let idleExpiry = grace.update([app("idle", playing: false)], now: start)
        #expect(idleExpiry == nil)
        #expect(!grace.contains("idle"), "从未播放的应用不应创建管线")
        _ = grace.update([app("a", playing: true)], now: start)
        let exitedExpiry = grace.update([], now: start + .seconds(1))
        #expect(exitedExpiry == nil)
        #expect(!grace.contains("a"), "进程退出后立即释放")
    }

    @Test func earliestExpiryIsReportedAndResetClears() {
        var grace = AudioPlaybackGrace()
        let start = ContinuousClock.now
        _ = grace.update([app("a", playing: true)], now: start)
        _ = grace.update([app("a", playing: false), app("b", playing: true)], now: start + .seconds(20))
        let expiry = grace.update([app("a", playing: false), app("b", playing: false)], now: start + .seconds(30))
        #expect(expiry == start + AudioPlaybackGrace.duration)
        grace.reset()
        #expect(!grace.contains("a") && !grace.contains("b"))
    }
}

struct AudioMixRequestTrackerTests {
    private func request(_ level: Double, output: String? = "out") -> AudioMixRequestTracker.Request {
        .init(targets: [AudioMixTarget(id: "a", processObjectIDs: [1], volume: AudioAppVolume(level: level)!)], outputUID: output)
    }

    @Test func identicalRequestDoesNotInterruptAndIsRecheckedAfterwards() throws {
        var tracker = AudioMixRequestTracker()
        let firstGeneration = tracker.begin(request(0.5))
        let first = try #require(firstGeneration)
        let duplicate = tracker.begin(request(0.5))
        #expect(duplicate == nil, "HAL 事件触发的相同请求不能打断正在等待首帧的重建")
        let firstRecheck = tracker.finish(first)
        #expect(firstRecheck, "期间收到的相同请求需在结束后核对一次（如流格式变化）")
        let secondGeneration = tracker.begin(request(0.5))
        let second = try #require(secondGeneration, "完成后相同请求可再次执行")
        let cleanRecheck = tracker.finish(second)
        #expect(!cleanRecheck, "没有重复请求时无需复核，避免循环")
    }

    @Test func changedRequestSupersedesAndStaleCompletionIsIgnored() throws {
        var tracker = AudioMixRequestTracker()
        let firstGeneration = tracker.begin(request(0.5))
        let first = try #require(firstGeneration)
        let sameAsFirst = tracker.begin(request(0.5))
        #expect(sameAsFirst == nil)
        let secondGeneration = tracker.begin(request(0.2))
        let second = try #require(secondGeneration, "用户调整音量必须立即生效")
        let supersededRecheck = tracker.finish(first)
        #expect(!supersededRecheck, "被取代的旧任务结束不能清除新请求")
        let sameAsSecond = tracker.begin(request(0.2))
        #expect(sameAsSecond == nil, "新请求仍在进行中")
        let secondRecheck = tracker.finish(second)
        #expect(secondRecheck)
        let otherOutput = tracker.begin(request(0.2, output: "other"))
        #expect(otherOutput != nil, "输出设备变化视为不同请求")
    }

    @Test func resetAllowsTheSameRequestImmediately() throws {
        var tracker = AudioMixRequestTracker()
        let firstGeneration = tracker.begin(request(0.5))
        let first = try #require(firstGeneration)
        _ = tracker.begin(request(0.5))
        tracker.reset()
        let staleRecheck = tracker.finish(first)
        #expect(!staleRecheck, "重置后旧完成事件不应触发复核")
        let afterReset = tracker.begin(request(0.5))
        #expect(afterReset != nil)
    }
}
