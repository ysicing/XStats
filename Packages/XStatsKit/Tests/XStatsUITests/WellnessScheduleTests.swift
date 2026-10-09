// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

struct WellnessScheduleTests {
    @Test func remindersDefaultOffAndIgnoreRemovedPreferences() throws {
        let legacy = Data(#"{"breakEnabled":false,"breakIntervalMinutes":30,"breakSeconds":60,"waterEnabled":true,"waterIntervalMinutes":60,"breathingMinutes":3,"breathingPattern":"gentle","waterGoal":8}"#.utf8)
        let preferences = try JSONDecoder().decode(WellnessPreferences.self, from: legacy)
        var schedule = HealthReminderSchedule()
        schedule.configure(preferences: preferences, enabled: true, at: 0)
        #expect(schedule.nextWake() == nil && schedule.pending.isEmpty)
        let encoded = try JSONEncoder().encode(preferences)
        let keys = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(keys.keys) == ["breakEnabled", "breakIntervalMinutes", "breakSeconds"])
    }

    @Test func independentDueEventsMergeAtNearbyBreakAndDoNotRepeat() {
        var preferences = WellnessPreferences(); preferences.breakEnabled = true
        var schedule = HealthReminderSchedule()
        schedule.configure(preferences: preferences, enabled: true, at: 0)
        #expect(schedule.nextWake(focusBreakAt: 2100) == 2100)
        #expect(schedule.nextWake(focusBreakAt: 2101) == 1800)
        #expect(schedule.due(at: 1800, focusBreakAt: 2100).isEmpty)
        #expect(schedule.due(at: 2100, focusBreakAt: 2100) == [.rest])
        #expect(schedule.due(at: 2200).isEmpty)
        schedule.acknowledge(.rest, at: 2200)
        #expect(schedule.nextWake() == 4000)
    }

    @Test func earlyBreakPostponeAndSuspensionKeepOneDeadline() {
        var preferences = WellnessPreferences(); preferences.breakEnabled = true
        var schedule = HealthReminderSchedule()
        schedule.configure(preferences: preferences, enabled: true, at: 0)
        #expect(schedule.mergeForBreak(at: 1500) == [.rest])
        schedule.postpone(.rest, at: 1500); #expect(schedule.nextWake() == 2100)
        schedule.suspend(at: 1600); #expect(schedule.nextWake() == nil)
        schedule.resume(at: 10000); #expect(schedule.nextWake() == 10500)
        schedule.configure(preferences: preferences, enabled: false, at: 10000)
        #expect(schedule.nextWake() == nil && schedule.pending.isEmpty)
    }
}
