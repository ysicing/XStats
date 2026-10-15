// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
import ScreenCaptureKit
import AVFoundation
@testable import CaptureCore
@testable import CaptureUI

@Suite @MainActor struct CaptureFinalizationTests {
    private func videoFrame(timestamp: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
    @Test func emptyFinalizationReleasesRecorderAndTemporaryMedia() async throws {
        _ = NSApplication.shared
        let media = try RecordingMedia()
        let recorder = ScreenRecorder(media: media)
        let controller = CaptureController(host: .embedded)
        defer { controller.cleanUp() }
        await controller.finalizeRecording(recorder)
        #expect(!controller.hasRecordingMedia)
        #expect(!controller.hasUnsavedWork)
        #expect(!FileManager.default.fileExists(atPath: media.directory.path))
        await controller.discardAndStop()
    }
    @Test func retryClearsTransientPermissionFailure() async throws {
        _ = NSApplication.shared
        let media = try RecordingMedia()
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        var attempts = 0
        let recorder = ScreenRecorder(media: media, stream: stream) { _ in
            attempts += 1
            if attempts == 1 { throw CaptureError.screenPermission }
        }
        let controller = CaptureController(host: .embedded)
        defer { controller.cleanUp() }
        await controller.finalizeRecording(recorder)
        #expect(controller.needsStopRetry)
        #expect(controller.permissionError == .screenPermission)
        await controller.finalizeRecording(recorder)
        #expect(controller.permissionError == nil)
        #expect(!controller.hasRecordingMedia)
        await controller.discardAndStop()
    }
    @Test func writerFailureDuringFailedStopSurvivesSuccessfulRetry() async throws {
        _ = NSApplication.shared
        let media = try RecordingMedia()
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        var attempts = 0
        // Inject the error at the Core stop boundary; reproducing physical disk
        // failure is outside this controller test. The real recorder retains its stream.
        let recorder = ScreenRecorder(media: media, stream: stream) { _ in
            attempts += 1
            if attempts == 1 { throw CaptureError.writerFailed }
        }
        let controller = CaptureController(host: .embedded)
        defer { controller.cleanUp() }
        await controller.finalizeRecording(recorder)
        #expect(controller.needsStopRetry)
        #expect(controller.error == CaptureError.writerFailed.localizedDescription)
        await controller.finalizeRecording(recorder)
        #expect(controller.error == CaptureError.writerFailed.localizedDescription)
        #expect(!controller.hasRecordingMedia)
        await controller.discardAndStop()
    }
    @Test(arguments: [false, true])
    func successfulRetryOpensPlayablePreviewAndKeepsOnlyTerminalErrors(terminalFailure: Bool) async throws {
        _ = NSApplication.shared
        let media = try RecordingMedia()
        let url = media.newSegmentURL()
        let writer = RecordingWriter { _ in }
        var options = RecordingOptions(); options.systemAudio = false
        try await writer.prepare(url: url, size: CGSize(width: 64, height: 48), options: options)
        let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds - 1
        for index in 0..<2 {
            let frame = try videoFrame(timestamp: origin + Double(index) / 30)
            writer.queue.sync { writer.consumeVideo(frame) }
            try await Task.sleep(for: .milliseconds(20))
        }
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        var attempts = 0
        let recorder = ScreenRecorder(media: media, stream: stream, writer: writer, activeURL: url) { _ in
            attempts += 1
            if attempts == 1 { throw CaptureError.screenPermission }
        }
        let controller = CaptureController(host: .embedded)
        defer { controller.cleanUp() }
        if terminalFailure { controller.recordingFailed(.microphoneFailed) }
        await controller.finalizeRecording(recorder)
        #expect(controller.needsStopRetry)
        await controller.finalizeRecording(recorder)
        #expect(controller.player != nil)
        #expect(controller.duration > 0)
        #expect(controller.error == (terminalFailure ? CaptureError.microphoneFailed.localizedDescription : nil))
        #expect(controller.permissionError == nil)
        #expect(!controller.busy)
        await controller.discardAndStop()
        #expect(!FileManager.default.fileExists(atPath: media.directory.path))
    }
    @Test func terminationPromptIsAboveFullscreenSelection() {
        _ = NSApplication.shared
        let alert = CaptureWorkspace.terminationAlert()
        #expect(alert.window.level.rawValue > NSWindow.Level.screenSaver.rawValue)
    }
    @Test func fittingExpandedHomeKeepsControlsInsideVisibleScreen() async throws {
        _ = NSApplication.shared
        let controller = CaptureController(host: .embedded)
        controller.showHome()
        let window = try #require(NSApp.windows.first { $0.delegate === controller })
        window.animationBehavior = .none
        let screen = try #require(window.screen)
        window.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY))
        controller.captureAction = .record
        controller.error = String(repeating: "Long localized error. ", count: 20)
        controller.fitHomeWindow()
        for _ in 0..<40 { await Task.yield() }
        #expect(window.frame.minY >= screen.visibleFrame.minY)
        #expect(window.frame.maxY <= screen.visibleFrame.maxY)
        await controller.discardAndStop()
        controller.cleanUp()
    }
}
