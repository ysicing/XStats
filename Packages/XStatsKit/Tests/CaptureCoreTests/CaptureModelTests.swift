// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import Foundation
import CoreGraphics
import ScreenCaptureKit
import AVFoundation
@testable import CaptureCore

@Suite struct CaptureModelTests {
    @Test func recordingErrorsKeepTheirRecoveryMeaning() {
        for failure in [CaptureError.screenPermission, .microphonePermission, .unavailableTarget, .captureFailed, .writerFailed] {
            #expect(CaptureError.recordingFailure(failure) == failure)
        }
        #expect(CaptureError.recordingFailure(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)) == .screenPermission)
        #expect(CaptureError.recordingFailure(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noCaptureSource.rawValue)) == .unavailableTarget)
        #expect(CaptureError.recordingFailure(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStart.rawValue)) == .captureFailed)
        #expect(CaptureError.recordingFailure(CocoaError(.fileWriteOutOfSpace)) == .writerFailed)
    }
    @Test func microphoneErrorsNeverSuggestDiskRecovery() {
        #expect(CaptureError.microphoneFailure(nil) == .microphoneFailed)
        #expect(CaptureError.microphoneFailure(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.deviceWasDisconnected.rawValue)) == .microphoneFailed)
        #expect(CaptureError.microphoneFailure(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.applicationIsNotAuthorizedToUseDevice.rawValue)) == .microphonePermission)
        #expect(CaptureError.recordingFailure(CaptureError.microphoneFailed) == .microphoneFailed)
    }
    @Test func versionedRequestsRejectUnexpectedInput() throws {
        #expect(try CaptureRequest(url: URL(string: "xstats-capture://v1/screenshot")!).action == .screenshot)
        #expect(throws: CaptureError.self) { try CaptureRequest(url: URL(string: "xstats-capture://v2/record")!) }
        #expect(throws: CaptureError.self) { try CaptureRequest(url: URL(string: "https://v1/record")!) }
        #expect(throws: CaptureError.self) { try CaptureRequest(url: URL(string: "xstats-capture://v1/record?file=/tmp/unsafe")!) }
    }
    @Test func regionConvertsNegativeOriginAndRetinaScale() throws {
        let display = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        let region = CGRect(x: -1400, y: 700, width: 200, height: 100)
        let result = try CaptureGeometry.region(region, in: display, scale: 2)
        #expect(result.sourceRect == CGRect(x: 40, y: 200, width: 200, height: 100))
        #expect(result.pixelSize == CGSize(width: 400, height: 200))
        #expect(throws: CaptureError.self) { try CaptureGeometry.region(.zero, in: display, scale: 2) }
    }
    @Test func recordingSizeIsEvenBoundedAndNeverUpscaled() {
        #expect(CaptureGeometry.recordingSize(CGSize(width: 6016, height: 3384)) == CGSize(width: 3840, height: 2160))
        #expect(CaptureGeometry.recordingSize(CGSize(width: 101, height: 99)) == CGSize(width: 100, height: 98))
    }
    @Test func pauseRemovesGapFromCommonClock() throws {
        var clock = RecordingClock()
        try clock.start(at: 100)
        #expect(clock.presentationTime(at: 102) == 2)
        try clock.pause(at: 103)
        #expect(clock.presentationTime(at: 110) == nil)
        try clock.resume(at: 113)
        #expect(clock.presentationTime(at: 114) == 4)
        try clock.pause(at: 115)
        try clock.resume(at: 120)
        #expect(clock.presentationTime(at: 121) == 6)
    }
    @Test func elapsedTimeFreezesDuringPausesAndResetsForNextRecording() throws {
        var clock = RecordingClock()
        #expect(clock.elapsedTime(at: 99) == 0)
        try clock.start(at: 100)
        #expect(clock.elapsedTime(at: 102.5) == 2.5)
        try clock.pause(at: 103)
        #expect(clock.elapsedTime(at: 113) == 3)
        try clock.resume(at: 113)
        #expect(clock.elapsedTime(at: 114) == 4)
        try clock.pause(at: 115)
        #expect(clock.elapsedTime(at: 4000) == 5)
        clock = RecordingClock()
        try clock.start(at: 5000)
        #expect(clock.elapsedTime(at: 5001) == 1)
    }
    @Test func statePreventsConcurrentStartAndStopDuringTransition() throws {
        var state = CaptureSessionState()
        try state.transition(to: .selecting)
        #expect(throws: CaptureError.self) { try state.transition(to: .selecting) }
        try state.transition(to: .countdown)
        try state.transition(to: .recording)
        try state.transition(to: .paused)
        try state.transition(to: .finishing)
        #expect(throws: CaptureError.self) { try state.transition(to: .recording) }
        try state.transition(to: .preview)
        try state.transition(to: .idle)
    }
    @Test func failedPauseOrResumeCanFinalizeAndRetryFromIdle() throws {
        for phase in [CaptureSessionState.Phase.pausing, .resuming] {
            var state = CaptureSessionState()
            try state.transition(to: .selecting); try state.transition(to: .countdown); try state.transition(to: .starting)
            try state.transition(to: .recording); try state.transition(to: .pausing)
            if phase == .resuming { try state.transition(to: .paused); try state.transition(to: .resuming) }
            try state.transition(to: .finishing); try state.transition(to: .preview)
            try state.transition(to: .idle); try state.transition(to: .finishing)
            try state.transition(to: .preview)
        }
    }
    @Test func cancelledSelectionCanStartAgain() throws {
        var state = CaptureSessionState()
        try state.transition(to: .selecting); try state.transition(to: .idle)
        try state.transition(to: .selecting)
        #expect(state.isBusy)
    }
    @Test func lockAndSleepInterruptCaptureButNotExport() throws {
        var state = CaptureSessionState()
        #expect(!state.shouldInterruptCapture)
        try state.transition(to: .selecting); #expect(state.shouldInterruptCapture)
        try state.transition(to: .countdown); try state.transition(to: .starting)
        try state.transition(to: .recording); #expect(state.shouldInterruptCapture)
        try state.transition(to: .pausing); try state.transition(to: .paused)
        #expect(state.shouldInterruptCapture)
        try state.transition(to: .finishing); #expect(!state.shouldInterruptCapture)
        try state.transition(to: .preview); #expect(!state.shouldInterruptCapture)
        try state.transition(to: .exporting); #expect(!state.shouldInterruptCapture)
    }
    @Test func audioDefaultsAndLifecycle() {
        #expect(RecordingOptions().systemAudio)
        #expect(!RecordingOptions().microphone)
        #expect(CaptureLifetime.shouldExit(resident: false, windows: 0, busy: false))
        #expect(!CaptureLifetime.shouldExit(resident: false, windows: 0, busy: true))
        #expect(!CaptureLifetime.shouldExit(resident: true, windows: 0, busy: false))
    }
    @Test func trimRejectsEmptyAndOutOfBoundsRanges() throws {
        #expect(try RecordingTrim(start: 1, end: 4, duration: 5).duration == 3)
        #expect(throws: CaptureError.self) { try RecordingTrim(start: 4, end: 1, duration: 5) }
        #expect(throws: CaptureError.self) { try RecordingTrim(start: -1, end: 2, duration: 5) }
    }
}
