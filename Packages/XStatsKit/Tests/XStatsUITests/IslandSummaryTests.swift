// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Foundation
@testable import Metrics
import Testing
@testable import XStatsUI

struct IslandSummaryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func account(id: String = "codex", stale: Bool = false, windows: [IslandQuotaAccount.Window]) -> IslandQuotaAccount {
        .init(id: id, title: id, windows: windows, updatedAt: now, stale: stale, status: nil)
    }

    @Test func absentBatteryIsFilteredWithoutOverwritingSavedScenes() {
        var prefs = IslandPreferences()
        prefs.scene = .battery
        prefs.scenes = [.ai, .battery]
        let resolved = prefs.available(hasInternalBattery: false)
        #expect(resolved.scenes == [.ai] && resolved.scene == .ai)
        #expect(prefs.scenes == [.ai, .battery] && prefs.scene == .battery)
        #expect(prefs.available(hasInternalBattery: nil).scene == .battery)
        #expect(prefs.available(hasInternalBattery: true).scene == .battery)
        prefs.scenes = [.battery]
        #expect(prefs.available(hasInternalBattery: false).scenes.isEmpty)
    }

    @Test func disabledContentIsFilteredWithoutRestoringCPUOrChangingSavedChoices() {
        var prefs = IslandPreferences()
        prefs.scene = .ai
        prefs.systemMetrics = [.cpu, .memory, .temperature, .power]
        let available = prefs.available(hasInternalBattery: false, enabledMetrics: [.memory], aiEnabled: false, restEnabled: false)
        #expect(available.scenes == [.system] && available.scene == .system)
        #expect(available.systemMetrics == [.memory] && available.primaryMetric == .memory)
        #expect(prefs.scene == .ai && prefs.scenes == IslandScene.allCases)
        #expect(prefs.systemMetrics == IslandSystemMetric.allCases)
        prefs.systemMetrics = [.cpu]
        let empty = prefs.available(hasInternalBattery: false, enabledMetrics: [.memory], aiEnabled: false, restEnabled: false)
        #expect(empty.scenes.isEmpty && empty.systemMetrics.isEmpty && empty.primaryMetric == nil)
        #expect(prefs.available(hasInternalBattery: true).scene == .ai)
        #expect(prefs.available(hasInternalBattery: true).primaryMetric == .cpu)
    }

    @Test func quotaChoosesTightestValidWindowWithinSelectedAccount() {
        let windows: [IslandQuotaAccount.Window] = [
            .init(id: "expired", title: "", remaining: 0, resetsAt: now),
            .init(id: "unknown", title: "", remaining: nil, resetsAt: nil),
            .init(id: "invalid", title: "", remaining: .nan, resetsAt: nil),
            .init(id: "unlimited", title: "", remaining: 0, resetsAt: nil, unlimited: true),
            .init(id: "weekly", title: "", remaining: 50, resetsAt: now.addingTimeInterval(60)),
            .init(id: "session", title: "", remaining: 10, resetsAt: nil),
        ]
        let a = account(windows: windows)
        let b = account(id: "other", windows: [.init(id: "depleted", title: "", remaining: 0, resetsAt: nil)])
        #expect(a.primary(at: now)?.id == "session")
        #expect(IslandQuotaAccount.selected(in: [b, a], id: a.id)?.primary(at: now)?.id == "session")
        #expect(IslandQuotaAccount.selected(in: [a, b], id: "removed") == nil)
        #expect(IslandQuotaAccount.selected(in: [a, b], id: "")?.id == a.id)
        let unlimited = account(windows: Array(windows.prefix(4)))
        #expect(unlimited.primary(at: now) == nil)
        #expect(unlimited.displayWindow(at: now)?.unlimited == true)
        #expect(account(windows: Array(windows.prefix(2))).displayWindow(at: now)?.id == "unknown")
    }

    @Test func automaticAccountSkipsUnconfiguredExpiredAndStaleSourcesButPinnedAccountRemains() {
        let missing = account(id: "missing", windows: [])
        let expired = account(id: "expired", windows: [.init(id: "old", title: "", remaining: 0, resetsAt: now)])
        let valid = account(id: "valid", windows: [.init(id: "session", title: "", remaining: 10, resetsAt: nil)])
        let stale = account(id: "stale", stale: true, windows: valid.windows)
        let sources = [missing, expired, stale, valid]
        #expect(IslandQuotaAccount.selected(in: sources, id: "", at: now)?.id == valid.id)
        #expect(IslandQuotaAccount.selected(in: sources, id: missing.id, at: now)?.id == missing.id)
        #expect(IslandQuotaAccount.selected(in: sources, id: stale.id, at: now)?.id == stale.id)
        #expect(IslandQuotaAccount.selected(in: [missing, stale], id: "", at: now)?.id == stale.id)
    }

    @Test func automaticFocusIgnoresStaleAndExpiredQuotaAndRespectsSceneSelection() {
        var prefs = IslandPreferences()
        let exhausted = account(windows: [.init(id: "weekly", title: "", remaining: 0, resetsAt: now.addingTimeInterval(1))])
        #expect(IslandFocus.scene(preferences: prefs, battery: nil, quota: exhausted, at: now) == .system)
        prefs.automaticFocus = true
        #expect(IslandFocus.scene(preferences: prefs, battery: nil, quota: exhausted, at: now) == .ai)
        #expect(IslandFocus.scene(preferences: prefs, battery: nil, quota: exhausted, at: now.addingTimeInterval(1)) == .system)
        let stale = account(stale: true, windows: exhausted.windows)
        #expect(IslandFocus.scene(preferences: prefs, battery: nil, quota: stale, at: now) == .system)
        prefs.scenes = [.system, .battery]
        #expect(IslandFocus.scene(preferences: prefs, battery: nil, quota: exhausted, at: now) == .system)
    }

    @Test func batteryOnlyInterruptsWhenLowAndDischarging() {
        var prefs = IslandPreferences()
        prefs.automaticFocus = true
        var battery = BatteryStatus(level: 0.1, isCharging: false, isPluggedIn: false, isFullyCharged: false)
        #expect(IslandFocus.scene(preferences: prefs, battery: battery, quota: nil, at: now) == .battery)
        battery.isPluggedIn = true
        #expect(IslandFocus.scene(preferences: prefs, battery: battery, quota: nil, at: now) == .system)
        battery.isPluggedIn = false
        battery.level = 0.11
        #expect(IslandFocus.scene(preferences: prefs, battery: battery, quota: nil, at: now) == .system)
    }

    @Test func paceRequiresReliableCurrentCycleAndMatchesDisplayDirection() {
        var window = IslandQuotaAccount.Window(id: "session", title: "", remaining: 60,
            resetsAt: now.addingTimeInterval(3600))
        #expect(window.paceFraction(at: now, showsRemaining: true) == nil)
        window.duration = 5 * 3600
        #expect(window.paceFraction(at: now, showsRemaining: true) == 0.2)
        #expect(window.paceFraction(at: now, showsRemaining: false) == 0.8)
        #expect(window.paceFraction(at: now.addingTimeInterval(3600), showsRemaining: true) == nil)
        #expect(window.paceFraction(at: now.addingTimeInterval(-5 * 3600), showsRemaining: true) == nil)
        window.unlimited = true
        #expect(window.paceFraction(at: now, showsRemaining: true) == nil)
        window.unlimited = false
        let invalid = IslandQuotaAccount.Window(id: "invalid", title: "", remaining: .nan,
            resetsAt: now.addingTimeInterval(3600), duration: 5 * 3600)
        #expect(invalid.paceFraction(at: now, showsRemaining: true) == nil)
    }

    @Test func powerEventsRequireTransitionsAndDoNotRepeatOrTreatChargePausesAsUnplugging() {
        var battery = BatteryStatus(level: 0.5, isCharging: false, isPluggedIn: false, isFullyCharged: false)
        #expect(IslandPowerNotice.event(previous: nil, current: battery) == nil)
        let unplugged = battery
        battery.isPluggedIn = true
        #expect(IslandPowerNotice.event(previous: unplugged, current: battery) == .connected)
        #expect(IslandPowerNotice.event(previous: battery, current: battery) == nil)
        let plugged = battery
        battery.isCharging = true
        #expect(IslandPowerNotice.event(previous: plugged, current: battery) == nil)
        battery.isFullyCharged = true
        #expect(IslandPowerNotice.event(previous: plugged, current: battery) == .fullyCharged)
        #expect(IslandPowerNotice.event(previous: battery, current: unplugged) == .disconnected)
        battery = unplugged
        battery.level = 0.2
        #expect(IslandPowerNotice.event(previous: unplugged, current: battery) == .lowBattery)
        let low = battery
        battery.level = 0.19
        #expect(IslandPowerNotice.event(previous: low, current: battery) == nil)
    }

    @Test func newPreferencesMigrateWithoutChangingExistingSceneValues() throws {
        #expect(IslandScene.focus.rawValue == 2)
        #expect(IslandScene.battery.rawValue == 3)
        let old = try JSONDecoder().decode(IslandPreferences.self, from: Data(#"{"enabled":true,"scene":2,"scenes":[0,1,2]}"#.utf8))
        #expect(old.enabled && old.scene == .focus && !old.automaticFocus && old.quotaAccountID.isEmpty)
        #expect(old.scenes == [.system, .ai, .focus])
        #expect(IslandQuotaAccount.identity("private@example.com") == IslandQuotaAccount.identity("private@example.com"))
        #expect(!IslandQuotaAccount.identity("private@example.com").contains("private"))
    }
}
