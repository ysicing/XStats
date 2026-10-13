// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import ScreenCaptureKit
import OSLog

/// All mutable writer state and delegate callbacks are confined to `queue`.
/// The only cross-queue operations schedule work onto that same serial queue.
final class RecordingWriter: NSObject, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "work.12306.xstats.capture.writer", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var systemAudio: AVAssetWriterInput?
    private var microphone: AVAssetWriterInput?
    private var origin: CMTime?
    private var failed = false
    private var finishing = false
    private var microphoneClock: CMClock?
    private static let logger = Logger(subsystem: CaptureRequest.bundleIdentifier, category: "writer")
    private let onFailure: @Sendable (CaptureError) -> Void
    init(onFailure: @escaping @Sendable (CaptureError) -> Void) { self.onFailure = onFailure }

    func prepare(url: URL, size: CGSize, options: RecordingOptions) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, Int(size.width * size.height * 4)), AVVideoExpectedSourceFrameRateKey: 30]])
                    video.expectsMediaDataInRealTime = true
                    guard writer.canAdd(video) else { throw CaptureError.writerFailed }
                    writer.add(video)
                    var system: AVAssetWriterInput?
                    var mic: AVAssetWriterInput?
                    for (enabled, isMic) in [(options.systemAudio, false), (options.microphone, true)] where enabled {
                        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: 48000, AVNumberOfChannelsKey: isMic ? 1 : 2, AVEncoderBitRateKey: isMic ? 96000 : 192000])
                        input.expectsMediaDataInRealTime = true
                        guard writer.canAdd(input) else { throw CaptureError.writerFailed }
                        writer.add(input)
                        if isMic { mic = input } else { system = input }
                    }
                    self.writer = writer; self.video = video; self.systemAudio = system; self.microphone = mic
                    self.origin = nil; self.failed = false; self.finishing = false
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            consumeVideo(sampleBuffer)
        } else if type == .audio { consumeAudio(sampleBuffer, microphone: false) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        consumeAudio(sampleBuffer, microphone: true)
    }
    func consumeVideo(_ sample: CMSampleBuffer) { append(sample, to: video, isVideo: true) }
    func consumeAudio(_ sample: CMSampleBuffer, microphone isMicrophone: Bool) {
        append(sample, to: isMicrophone ? microphone : systemAudio, isVideo: false, clock: isMicrophone ? microphoneClock : nil)
    }
    func setMicrophoneClock(_ clock: CMClock?) async {
        await withCheckedContinuation { continuation in
            queue.async { self.microphoneClock = clock; continuation.resume() }
        }
    }
    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?, isVideo: Bool, clock: CMClock? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finishing, !failed, let writer, let input else { return }
        let rawTimestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        let timestamp = clock.map { CMSyncConvertTime(rawTimestamp, from: $0, to: CMClockGetHostTimeClock()) } ?? rawTimestamp
        if origin == nil {
            guard isVideo else { return }
            guard writer.startWriting() else { fail(); return }
            origin = timestamp; writer.startSession(atSourceTime: .zero)
        }
        guard let origin, RecordingSampleTime.relative(sample: timestamp.seconds, origin: origin.seconds) != nil else { return }
        guard input.isReadyForMoreMediaData else {
            if !isVideo { fail() }
            return
        }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr else { fail(); return }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else { fail(); return }
        for index in timings.indices {
            let time = timings[index].presentationTimeStamp
            timings[index].presentationTimeStamp = (clock.map { CMSyncConvertTime(time, from: $0, to: CMClockGetHostTimeClock()) } ?? time) - origin
            if timings[index].decodeTimeStamp.isValid { timings[index].decodeTimeStamp = timings[index].decodeTimeStamp - origin }
        }
        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: timings.count,
                                                  sampleTimingArray: &timings, sampleBufferOut: &adjusted) == noErr,
              let adjusted, input.append(adjusted) else { fail(); return }
    }
    func reportAudioFailure() { queue.async { if !self.finishing { self.fail() } } }
    private func fail() {
        guard !failed else { return }
        failed = true
        Self.logger.error("Media writer failed")
        onFailure(.writerFailed)
    }
    func finish(endTime: CMTime? = nil) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.finishing = true
                guard let writer = self.writer, self.origin != nil else {
                    self.writer?.cancelWriting(); self.clear(); continuation.resume(returning: false); return
                }
                if let endTime, let origin = self.origin, endTime > origin, writer.status == .writing {
                    writer.endSession(atSourceTime: endTime - origin)
                }
                self.video?.markAsFinished(); self.systemAudio?.markAsFinished(); self.microphone?.markAsFinished()
                writer.finishWriting {
                    self.queue.async {
                        let completed = self.writer?.status == .completed
                        self.clear()
                        if completed { continuation.resume(returning: true) }
                        else { continuation.resume(throwing: CaptureError.writerFailed) }
                    }
                }
            }
        }
    }
    private func clear() { writer = nil; video = nil; systemAudio = nil; microphone = nil; origin = nil }
}
