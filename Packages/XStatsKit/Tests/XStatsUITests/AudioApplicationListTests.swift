// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AudioControl
import Foundation
import Testing
@testable import XStatsUI

struct AudioApplicationListTests {
    @MainActor @Test func resettingAnUnplayedPausedAppKeepsItsRowVisible() throws {
        let suite = "XStats.AudioApplicationListTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AudioController(defaults: defaults)
        defer { controller.stop() }
        let paused = app("adjusted", object: 11)
        controller.showPreview(AudioHardwareSnapshot(devices: [], outputID: nil, inputID: nil, applications: [paused]),
                               volumes: [paused.id: try #require(AudioAppVolume(level: 0.59))], outputs: [paused.id: "old-output"])
        // 同步检查重置结果，关闭展示需求，避免蓝牙读取或启动真实音频处理。
        controller.setDemand(enabled: true, visible: false, menuVisible: false)
        controller.resetApp(paused)
        #expect(controller.volumes.isEmpty)
        #expect(controller.outputRoutes.isEmpty)
        #expect(controller.listedApplications.map(\.id) == [paused.id])
        #expect(!controller.snapshot.applications[0].isPlaying)
    }

    @MainActor @Test func controllerFiltersTheUIWithoutDroppingRawApplicationData() throws {
        let suite = "XStats.AudioApplicationListTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AudioController(defaults: defaults)
        let apps = [app("com.apple.dock", object: 1), app("player", playing: true, object: 2), app("adjusted", object: 3)]
        controller.showPreview(AudioHardwareSnapshot(devices: [], outputID: nil, inputID: nil, applications: apps),
                               volumes: ["adjusted": try #require(AudioAppVolume(level: 0.59))], outputs: [:])
        #expect(controller.snapshot.applications.map(\.id) == ["com.apple.dock","player","adjusted"])
        #expect(controller.listedApplications.map(\.id) == ["player","adjusted"])
        let paused = [app("com.apple.dock", object: 1), app("player", object: 2), app("adjusted", object: 3)]
        controller.showPreview(AudioHardwareSnapshot(devices: [], outputID: nil, inputID: nil, applications: paused), volumes: controller.volumes, outputs: [:])
        #expect(controller.listedApplications.map(\.id) == ["player","adjusted"])
    }

    private func app(_ id: String, playing: Bool = false, object: UInt32 = 1) -> AudioApplication {
        AudioApplication(id: id, name: id, processObjectIDs: [object], isPlaying: playing)
    }

    @Test func inactiveRegisteredProcessesAreHiddenWhilePlayingAppsRemain() {
        let apps = [app("com.apple.dock", object: 1), app("com.apple.controlcenter", object: 2), app("player", playing: true, object: 3)]
        var list = AudioApplicationList()
        list.update(apps)
        #expect(list.visible(apps, volumes: [:], outputs: [:]).map(\.id) == ["player"])
    }

    @Test func pausedAppsWithVolumeMuteOrRoutingPreferencesRemainEditable() throws {
        let apps = [app("volume", object: 1), app("mute", object: 2), app("route", object: 3), app("idle", object: 4)]
        var list = AudioApplicationList()
        list.update(apps)
        let volumes = ["volume": try #require(AudioAppVolume(level: 0.59)), "mute": try #require(AudioAppVolume(level: 1, isMuted: true))]
        #expect(list.visible(apps, volumes: volumes, outputs: ["route":"missing-device"]).map(\.id) == ["volume","mute","route"])
    }

    @Test func previouslyPlayingAppsStayVisibleWhilePausedButNotAfterReconnecting() {
        var list = AudioApplicationList()
        list.update([app("player", playing: true, object: 11)])
        let paused = [app("player", object: 11)]
        list.update(paused)
        #expect(list.visible(paused, volumes: [:], outputs: [:]).map(\.id) == ["player"])
        let relaunched = [app("player", object: 12)]
        list.update(relaunched)
        #expect(list.visible(relaunched, volumes: [:], outputs: [:]).isEmpty)
    }

    @Test func explicitlyRetainedRowsExpireWhenTheirConnectionEndsOrTheModuleResets() {
        var list = AudioApplicationList()
        let paused = app("adjusted", object: 11)
        list.retain(paused)
        list.update([paused])
        #expect(list.visible([paused], volumes: [:], outputs: [:]).map(\.id) == [paused.id])
        let reconnected = app("adjusted", object: 12)
        list.update([reconnected])
        #expect(list.visible([reconnected], volumes: [:], outputs: [:]).isEmpty)
        list.retain(reconnected)
        list.reset()
        #expect(list.visible([reconnected], volumes: [:], outputs: [:]).isEmpty)
    }

    @Test func resettingTheModuleDiscardsPlaybackHistory() {
        var list = AudioApplicationList()
        list.update([app("player", playing: true)])
        list.reset()
        #expect(list.visible([app("player")], volumes: [:], outputs: [:]).isEmpty)
    }

    @Test func newObjectsRegisteredDuringPauseDoNotInheritPlaybackHistory() {
        var list = AudioApplicationList()
        list.update([app("player", playing: true, object: 11)])
        let overlapping = [AudioApplication(id: "player", name: "Player", processObjectIDs: [11,12], isPlaying: false)]
        list.update(overlapping)
        #expect(list.visible(overlapping, volumes: [:], outputs: [:]).count == 1)
        let idle = [app("player", object: 12)]
        list.update(idle)
        #expect(list.visible(idle, volumes: [:], outputs: [:]).isEmpty)
    }
}
