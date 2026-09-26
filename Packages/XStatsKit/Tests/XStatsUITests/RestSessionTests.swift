// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Testing
@testable import XStatsUI

@Suite struct RestSessionTests {
    @Test func deadlineDoesNotAccumulateTickError() {
        let start: UInt64 = 1_000_000_000
        var session = RestSession(now: start, workMinutes: 20, restMinutes: 3)
        session.resume(at: start)
        let workEnd = start + 20 * 60_000_000_000
        #expect(session.remaining(at: workEnd - 1_000_000) == 0.001)
        session.advance(to: workEnd + 500_000_000)
        #expect(session.phase == .rest)
        #expect(session.remaining(at: workEnd + 500_000_000) == 179.5)
    }

    @Test func sleepingAcrossMultiplePhasesUsesAbsoluteDeadline() {
        let start: UInt64 = 1_000_000_000
        var session = RestSession(now: start, workMinutes: 20, restMinutes: 3)
        session.resume(at: start)
        let completedAt = session.advance(to: start + 24 * 60_000_000_000, cycle: true)
        #expect(completedAt == [start + 20 * 60_000_000_000])
        #expect(session.phase == .work)
        #expect(session.remaining(at: start + 24 * 60_000_000_000) == 19 * 60)
    }

    @Test func skipStartsFreshWorkPeriod() {
        var session = RestSession(now: 0, workMinutes: 20, restMinutes: 3)
        session.resume(at: 0)
        session.advance(to: 20 * 60_000_000_000)
        session.skip(at: 21 * 60_000_000_000)
        #expect(session.phase == .work)
        #expect(session.remaining(at: 21 * 60_000_000_000) == 20 * 60)
    }

    @Test func pauseAndResumeKeepRemainingTime() {
        var session = RestSession(now: 0, workMinutes: 25, restMinutes: 5)
        #expect(!session.isRunning)
        session.resume(at: 0)
        session.pause(at: 10 * 60_000_000_000)
        #expect(session.remaining(at: 40 * 60_000_000_000) == 15 * 60)
        session.resume(at: 40 * 60_000_000_000)
        #expect(session.deadline == 55 * 60_000_000_000)
    }

    @Test func returningFromBreakKeepsCompletedFocusCount() {
        var session = RestSession(now: 0, workMinutes: 25, restMinutes: 5)
        session.resume(at: 0)
        session.advance(to: 25 * 60_000_000_000)
        session.select(.work, at: 25 * 60_000_000_000)
        #expect(session.phase == .work)
        #expect(!session.isRunning)
        #expect(session.completedFocus == 1)
        #expect(session.remaining(at: 25 * 60_000_000_000) == 25 * 60)
    }

    @Test func resettingBreakKeepsItsPhaseAndCompletedFocusCount() {
        var session = RestSession(now: 0, workMinutes: 25, restMinutes: 5)
        session.resume(at: 0)
        session.advance(to: 25 * 60_000_000_000)
        session.resetCurrentPhase(at: 26 * 60_000_000_000)
        #expect(session.phase == .rest)
        #expect(!session.isRunning)
        #expect(session.completedFocus == 1)
        #expect(session.remaining(at: 26 * 60_000_000_000) == 5 * 60)
    }

    @Test func pausedSwitchKeepsEachPhasesRemainingTimeUntilExplicitReset() {
        var session = RestSession(now: 0, workMinutes: 25, restMinutes: 5, longBreakMinutes: 15)
        session.resume(at: 0)
        session.pause(at: 5 * 60_000_000_000)
        session.select(.rest, at: 5 * 60_000_000_000)
        session.resume(at: 5 * 60_000_000_000)
        session.pause(at: 6 * 60_000_000_000)
        session.select(.longRest, at: 6 * 60_000_000_000)
        #expect(session.remaining(at: 6 * 60_000_000_000) == 15 * 60)
        session.select(.work, at: 6 * 60_000_000_000)
        #expect(!session.isRunning)
        #expect(session.remaining(at: 6 * 60_000_000_000) == 20 * 60)
        session.select(.rest, at: 6 * 60_000_000_000)
        #expect(session.remaining(at: 6 * 60_000_000_000) == 4 * 60)
        session.select(.rest, at: 7 * 60_000_000_000)
        #expect(session.remaining(at: 7 * 60_000_000_000) == 4 * 60)
        session.resetCurrentPhase(at: 7 * 60_000_000_000)
        #expect(session.remaining(at: 7 * 60_000_000_000) == 5 * 60)
    }

    @Test func switchingWhileRunningPreservesProgressAndContinueResumesIt() {
        var session = RestSession(now: 0, workMinutes: 25, restMinutes: 5)
        session.resume(at: 0)
        session.select(.rest, at: 5 * 60_000_000_000)
        session.select(.work, at: 5 * 60_000_000_000)
        #expect(!session.isRunning)
        #expect(session.canContinue)
        #expect(session.remaining(at: 5 * 60_000_000_000) == 20 * 60)
        session.startOrContinue(at: 5 * 60_000_000_000)
        #expect(session.isRunning)
        #expect(session.remaining(at: 5 * 60_000_000_000) == 20 * 60)
    }

    @Test func startAfterExplicitResetUsesFullDuration() {
        var session = RestSession(now: 0, workMinutes: 25, restMinutes: 5)
        session.resume(at: 0)
        session.pause(at: 5 * 60_000_000_000)
        #expect(session.canContinue)
        session.resetCurrentPhase(at: 5 * 60_000_000_000)
        #expect(!session.canContinue)
        session.startOrContinue(at: 5 * 60_000_000_000)
        #expect(session.remaining(at: 5 * 60_000_000_000) == 25 * 60)
    }

    @Test func automaticTransitionStartsNextBreakAtFullDuration() {
        var session = RestSession(now: 0, workMinutes: 25, restMinutes: 5)
        session.select(.rest, at: 0)
        session.resume(at: 0)
        session.pause(at: 60_000_000_000)
        session.select(.work, at: 60_000_000_000)
        session.resume(at: 60_000_000_000)
        session.advance(to: 26 * 60_000_000_000)
        #expect(session.phase == .rest)
        #expect(session.remaining(at: 26 * 60_000_000_000) == 5 * 60)
    }

    @Test func skipStartsTargetPhaseFreshDespiteSavedPause() {
        var session = RestSession(now: 0, workMinutes: 25, restMinutes: 5)
        session.select(.rest, at: 0)
        session.resume(at: 0)
        session.pause(at: 60_000_000_000)
        session.select(.work, at: 60_000_000_000)
        session.skip(at: 60_000_000_000)
        #expect(session.phase == .rest)
        #expect(session.isRunning)
        #expect(session.remaining(at: 60_000_000_000) == 5 * 60)
    }

    @Test func postponedFocusKeepsItsFiveMinuteScaleAfterSwitching() {
        var session = RestSession(now: 0, workMinutes: 25, restMinutes: 5)
        session.select(.rest, at: 0)
        session.postponeFocus(at: 0)
        session.pause(at: 60_000_000_000)
        session.select(.longRest, at: 60_000_000_000)
        session.select(.work, at: 60_000_000_000)
        #expect(session.phaseDuration == 5 * 60_000_000_000)
        #expect(session.remaining(at: 60_000_000_000) == 4 * 60)
    }

    @Test func singleModeStopsAfterBreakAndCycleContinues() {
        var single = RestSession(now: 0, workMinutes: 25, restMinutes: 5)
        single.resume(at: 0)
        single.advance(to: 31 * 60_000_000_000, cycle: false)
        #expect(single.phase == .work)
        #expect(!single.isRunning)
        #expect(single.completedFocus == 1)

        var cycle = RestSession(now: 0, workMinutes: 25, restMinutes: 5)
        cycle.resume(at: 0)
        cycle.advance(to: 31 * 60_000_000_000, cycle: true)
        #expect(cycle.phase == .work)
        #expect(cycle.isRunning)
        #expect(cycle.remaining(at: 31 * 60_000_000_000) == 24 * 60)
    }

    @Test func fourthFocusUsesLongBreak() {
        var session = RestSession(now: 0, workMinutes: 25, restMinutes: 5, longBreakMinutes: 15)
        session.resume(at: 0)
        session.advance(to: 115 * 60_000_000_000, cycle: true)
        #expect(session.phase == .longRest)
        #expect(session.completedFocus == 4)
        #expect(session.remaining(at: 115 * 60_000_000_000) == 15 * 60)
    }

    @Test func postponeAddsFiveMinutesAndDoesNotDoubleCountFocus() {
        var session = RestSession(now: 0, workMinutes: 25, restMinutes: 5)
        session.resume(at: 0)
        session.advance(to: 25 * 60_000_000_000)
        #expect(session.completedFocus == 1)
        session.postponeFocus(at: 25 * 60_000_000_000)
        #expect(session.phase == .work)
        #expect(session.completedFocus == 0)
        #expect(session.remaining(at: 25 * 60_000_000_000) == 5 * 60)
        session.advance(to: 30 * 60_000_000_000)
        #expect(session.completedFocus == 1)
    }
}

@MainActor
@Suite struct RestSettingsTests {
    @Test func userActionAfterDeadlineCreditsFocusBeforeChangingPhase() {
        let defaults = UserDefaults(suiteName: "RestDeadlineActionTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.restEnabled = true
        var now: UInt64 = 0
        let rest = RestController(settings: settings, localDefaults: defaults,
                                  sharedDefaults: defaults, clock: { now })
        rest.sync()
        rest.startPause()

        now = 25 * 60_000_000_000 + 1
        rest.startPause()
        #expect(rest.completedToday == 1)
        #expect(rest.phase == .rest)
        rest.stop()
    }

    @Test func switchingAfterDeadlineCreditsCompletedFocus() {
        let defaults = UserDefaults(suiteName: "RestDeadlineSwitchTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.restEnabled = true
        var now: UInt64 = 0
        let rest = RestController(settings: settings, localDefaults: defaults,
                                  sharedDefaults: defaults, clock: { now })
        rest.sync()
        rest.startPause()

        now = 25 * 60_000_000_000 + 1
        rest.selectPhase(.longRest)
        #expect(rest.completedToday == 1)
        #expect(rest.phase == .longRest)
        rest.stop()
    }

    @Test func controllerShowsContinueAfterSwitchingAwayFromActiveFocus() {
        let defaults = UserDefaults(suiteName: "RestContinueTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.restEnabled = true
        var now: UInt64 = 0
        let rest = RestController(settings: settings, localDefaults: defaults,
                                  sharedDefaults: defaults, clock: { now })
        rest.sync()
        rest.startPause()
        now = 5 * 60_000_000_000
        rest.selectPhase(.rest)
        rest.selectPhase(.work)
        #expect(rest.canContinue)
        #expect(rest.secondsRemaining == 20 * 60)
        rest.startPause()
        #expect(rest.isRunning)
        #expect(rest.secondsRemaining == 20 * 60)
        rest.stop()
    }

    @Test func hudWindowDragsFromTheTimerArea() throws {
        let window = RestPanel(contentRect: NSRect(x: 500, y: 500, width: 250, height: 160),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hudDragEnabled = true
        let start = window.frame.origin
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 125, y: 80),
                                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let dragged = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 100, y: 100),
                                                      modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(down)
        window.sendEvent(dragged)
        #expect(window.frame.origin.x == start.x - 25)
        #expect(window.frame.origin.y == start.y + 20)
        window.close()
    }

    @Test func hudActionButtonsDoNotStartAWindowDrag() throws {
        let window = RestPanel(contentRect: NSRect(x: 500, y: 500, width: 250, height: 160),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hudDragEnabled = true
        let start = window.frame.origin
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 220, y: 135),
                                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let dragged = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 150, y: 100),
                                                      modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(down)
        window.sendEvent(dragged)
        #expect(window.frame.origin == start)
        window.close()
    }

    @Test func hudStylesCycleInAStableOrder() {
        #expect(RestHUDStyle.countdown.next == .ring)
        #expect(RestHUDStyle.ring.next == .hourglass)
        #expect(RestHUDStyle.hourglass.next == .countdown)
    }

    @Test func disabledPomodoroDoesNotRestoreItsPage() {
        let defaults = UserDefaults(suiteName: "RestRouteTests.\(UUID())")!
        defaults.set("rest", forKey: "panelTab")
        #expect(AppSettings(defaults: defaults).panelTab == .settingsGeneral)
        defaults.set(true, forKey: "restEnabled")
        #expect(AppSettings(defaults: defaults).panelTab == .rest)
    }

    @Test func controllerRunsFocusBreakAndPostponeWithoutDoubleCredit() {
        let defaults = UserDefaults(suiteName: "RestFlowTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.restEnabled = true
        var now: UInt64 = 0
        let rest = RestController(settings: settings, localDefaults: defaults,
                                  sharedDefaults: defaults, clock: { now })
        var curtainChanges: [Bool] = []
        rest.onRestChange = { curtainChanges.append($0) }
        rest.sync()
        #expect(!rest.isRunning)
        rest.startPause()
        #expect(rest.isRunning)

        now = 25 * 60_000_000_000
        rest.sync()
        #expect(rest.phase == .rest)
        #expect(rest.completedToday == 1)
        #expect(curtainChanges == [true])

        rest.postponeFiveMinutes()
        #expect(rest.phase == .work)
        #expect(rest.completedToday == 0)
        #expect(curtainChanges == [true, false])

        now = 30 * 60_000_000_000
        rest.sync()
        #expect(rest.completedToday == 1)
        rest.prepareForTermination()
        #expect(defaults.bool(forKey: "rest.running") == false)
        rest.stop()
    }

    @Test func sleepingDoesNotCreditUnattendedFocus() {
        let defaults = UserDefaults(suiteName: "RestSleepTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.restEnabled = true
        var now: UInt64 = 0
        let rest = RestController(settings: settings, localDefaults: defaults,
                                  sharedDefaults: defaults, clock: { now })
        rest.sync()
        rest.startPause()
        now = 10 * 60_000_000_000
        rest.suspend()
        now = 25 * 60_000_000_000
        rest.sync()
        #expect(rest.phase == .rest)
        #expect(rest.completedToday == 0)
        rest.postponeFiveMinutes()
        #expect(rest.completedToday == 0)
        rest.stop()
    }

    @Test func disabledByDefaultAndBackupRestoresOnlyValidChoices() throws {
        let sourceDefaults = UserDefaults(suiteName: "RestSettingsTests.source.\(UUID())")!
        let targetDefaults = UserDefaults(suiteName: "RestSettingsTests.target.\(UUID())")!
        let source = AppSettings(defaults: sourceDefaults)
        #expect(!source.restEnabled)
        source.restEnabled = true
        source.restWorkMinutes = 45
        source.restBreakMinutes = 5
        source.restLongBreakMinutes = 20
        source.restDailyGoal = 12
        source.restCycleEnabled = true
        source.restSound = .rain
        source.restHUDStyle = .hourglass
        let document = try JSONDecoder().decode(SettingsDocument.self,
                                                from: JSONEncoder().encode(source.exportDocument()))
        let target = AppSettings(defaults: targetDefaults)
        target.apply(document)
        #expect(target.restEnabled)
        #expect(target.restWorkMinutes == 45)
        #expect(target.restBreakMinutes == 5)
        #expect(target.restLongBreakMinutes == 20)
        #expect(target.restDailyGoal == 12)
        #expect(target.restCycleEnabled)
        #expect(target.restSound == .rain)
        #expect(target.restHUDStyle == .hourglass)

        var invalid = SettingsDocument()
        invalid.restWorkMinutes = 999
        invalid.restLongBreakMinutes = -1
        invalid.restDailyGoal = 0
        invalid.restSound = "unknown"
        invalid.restHUDStyle = "unknown"
        target.apply(invalid)
        #expect(target.restWorkMinutes == 45)
        #expect(target.restLongBreakMinutes == 20)
        #expect(target.restDailyGoal == 12)
        #expect(target.restSound == .rain)
        #expect(target.restHUDStyle == .hourglass)
    }
}
