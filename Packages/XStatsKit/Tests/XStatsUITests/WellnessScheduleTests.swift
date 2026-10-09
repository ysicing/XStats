// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

/// 覆盖独立运行、合并时限、去重、暂停和配置失效，不依赖真实定时器。
struct WellnessScheduleTests {
    private var preferences: WellnessPreferences {
        var value = WellnessPreferences()
        value.breakEnabled = true
        value.waterEnabled = true
        return value
    }

    @Test func newRemindersAreOptInAndInvalidPreferencesAreNormalized() {
        let defaults = WellnessPreferences()
        #expect(!defaults.breakEnabled && !defaults.waterEnabled)
        var invalid = defaults
        invalid.breakIntervalMinutes = -1
        invalid.waterIntervalMinutes = Int.max
        invalid.breakSeconds = 0
        invalid.waterGoal = -5
        let normalized = invalid.normalized
        #expect(normalized.breakIntervalMinutes == 30)
        #expect(normalized.waterIntervalMinutes == 60)
        #expect(normalized.breakSeconds == 60)
        #expect(normalized.waterGoal == nil)
    }

    @Test func independentRemindersAndPendingEventsAreNotRepeated() {
        var schedule = HealthReminderSchedule()
        schedule.configure(preferences: preferences, enabled: true, at: 0)
        #expect(schedule.nextWake() == 1800)
        #expect(schedule.due(at: 1800) == [.rest])
        #expect(schedule.due(at: 1801).isEmpty)
        #expect(schedule.nextWake() == 3600)
        #expect(schedule.due(at: 3600) == [.water])
        schedule.acknowledge(.water, at: 3601)
        #expect(!schedule.pending.contains(.water))
        #expect(schedule.nextWake() == 7201)
    }

    @Test func focusDelaysOnlyToABreakWithinFiveMinutes() {
        var schedule = HealthReminderSchedule()
        schedule.configure(preferences: preferences, enabled: true, at: 0)
        #expect(schedule.nextWake(focusBreakAt: 2100) == 2100)
        #expect(schedule.due(at: 1800, focusBreakAt: 2100).isEmpty)
        #expect(schedule.due(at: 2100, focusBreakAt: 2100) == [.rest])
        var distant = HealthReminderSchedule()
        distant.configure(preferences: preferences, enabled: true, at: 0)
        #expect(distant.due(at: 1800, focusBreakAt: 2101) == [.rest])
    }

    @Test func upcomingRemindersMergeAtBreakAndWaterStillRequiresConfirmation() {
        var schedule = HealthReminderSchedule()
        schedule.configure(preferences: preferences, enabled: true, at: 0)
        #expect(schedule.mergeForBreak(at: 1500) == [.rest])
        schedule.acknowledge(.rest, at: 1800)
        #expect(schedule.nextWake() == 3600)
        #expect(schedule.mergeForBreak(at: 3300) == [.rest, .water])
        #expect(schedule.pending.contains(.water))
        schedule.acknowledge(.rest, at: 3600)
        #expect(schedule.pending == [.water])
    }

    @Test func sleepPreservesRemainingIntervalsAndDisabledFeaturesHaveNoWake() {
        var schedule = HealthReminderSchedule()
        schedule.configure(preferences: preferences, enabled: true, at: 0)
        schedule.suspend(at: 1000)
        #expect(schedule.nextWake() == nil)
        schedule.resume(at: 20_000)
        #expect(schedule.nextWake() == 20_800)
        #expect(schedule.due(at: 20_000).isEmpty)
        schedule.configure(preferences: preferences, enabled: false, at: 20_000)
        #expect(schedule.nextWake() == nil && schedule.pending.isEmpty)
    }

    @Test func unchangedSettingsDoNotRestartTimersAndPostponingReplacesPending() {
        var schedule = HealthReminderSchedule()
        schedule.configure(preferences: preferences, enabled: true, at: 0)
        schedule.configure(preferences: preferences, enabled: true, at: 100)
        #expect(schedule.nextWake() == 1800)
        _ = schedule.due(at: 1800)
        schedule.postpone(.rest, at: 1801)
        #expect(schedule.pending.isEmpty)
        #expect(schedule.nextWake() == 2401)
    }
}
