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
    private var wroteVideo = false
    private var failure: CaptureError?
    private var failed: Bool { failure != nil }
    private var finishing = false
    private var committedMedia = false
    private var finishCompletion: CaptureCallback<Bool>?
    private var microphoneClock: CMClock?
    private final class AudioBacklog {
        let input: AVAssetWriterInput
        let timeline = RecordingAudioTimeline()
        var samples: [CMSampleBuffer] = []
        var bytes = 0
        var stalledAt: UInt64?
        var finished = false
        init(_ input: AVAssetWriterInput) { self.input = input }
    }
    private var audioBacklogs: [AudioBacklog] = []
    private var audioDrainScheduled = false
    private var generation: UInt64 = 0
    private static let logger = Logger(subsystem: CaptureRequest.bundleIdentifier, category: "writer")
    private let onFailure: @Sendable (CaptureError) -> Void
    private let isReady: @Sendable (AVAssetWriterInput) -> Bool
    init(isReady: @escaping @Sendable (AVAssetWriterInput) -> Bool = { $0.isReadyForMoreMediaData },
         onFailure: @escaping @Sendable (CaptureError) -> Void) {
        self.isReady = isReady; self.onFailure = onFailure
    }

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
                    self.audioBacklogs = [system, mic].compactMap { $0 }.map(AudioBacklog.init)
                    self.origin = nil; self.wroteVideo = false; self.failure = nil; self.finishing = false; self.committedMedia = false
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
        // Video may drop frames under pressure. Audio must retain its samples:
        // AAC packs later PCM early if a middle buffer is silently discarded.
        if isVideo, !isReady(input) { return }
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
              let adjusted else { fail(); return }
        if isVideo {
            guard input.append(adjusted) else { fail(); return }
            wroteVideo = true
            return
        }
        guard let backlog = audioBacklogs.first(where: { $0.input === input }) else { fail(); return }
        drainAudio()
        guard !failed else { return }
        let samples: [CMSampleBuffer]
        do { samples = try backlog.timeline.normalize(adjusted) }
        catch { fail(); return }
        let bytes = samples.reduce(0) { $0 + CMSampleBufferGetTotalSampleSize($1) }
        guard samples.count <= 64 - audioBacklogs.reduce(0, { $0 + $1.samples.count }),
              bytes <= 4 * 1024 * 1024 - audioBacklogs.reduce(0, { $0 + $1.bytes }) else { fail(); return }
        backlog.samples.append(contentsOf: samples); backlog.bytes += bytes
        drainAudio()
        scheduleAudioDrain()
    }
    private func drainAudio() {
        for backlog in audioBacklogs {
            while let sample = backlog.samples.first, isReady(backlog.input) {
                guard backlog.input.append(sample) else { fail(); backlog.samples.removeAll(); backlog.bytes = 0; break }
                backlog.samples.removeFirst(); backlog.bytes -= CMSampleBufferGetTotalSampleSize(sample)
                backlog.stalledAt = nil
            }
            guard !backlog.samples.isEmpty else { backlog.stalledAt = nil; continue }
            let now = DispatchTime.now().uptimeNanoseconds
            if let start = backlog.stalledAt, now - start >= 1_000_000_000 {
                // Stop instead of silently moving later sound earlier. Retain
                // the already written media; no further producer samples enter.
                fail(); backlog.samples.removeAll(); backlog.bytes = 0
            } else if backlog.stalledAt == nil { backlog.stalledAt = now }
        }
    }
    private func scheduleAudioDrain() {
        guard !audioDrainScheduled, !finishing, !failed,
              audioBacklogs.contains(where: { !$0.samples.isEmpty }) else { return }
        audioDrainScheduled = true
        let current = generation
        queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            guard let self, self.generation == current else { return }
            self.audioDrainScheduled = false
            guard !self.finishing, !self.failed else { return }
            self.drainAudio(); self.scheduleAudioDrain()
        }
    }
    func reportAudioFailure(_ failure: CaptureError = .microphoneFailed) { queue.async { if !self.finishing { self.fail(failure) } } }
    private func fail(_ failure: CaptureError = .writerFailed) {
        guard !failed else { return }
        self.failure = failure
        Self.logger.error("Media pipeline failed")
        onFailure(failure)
    }
    func finish(endTime: CMTime? = nil) async throws -> Bool {
        let completion = CaptureCallback<Bool>()
        return try await completion.wait(onCancel: { self.cancel(completion) }) { completion in
            queue.async {
                guard !completion.isCancelled else { return }
                guard self.finishCompletion == nil else { completion.finish(.failure(CaptureError.invalidTransition)); return }
                self.finishCompletion = completion
                self.finishing = true
                guard self.writer != nil, self.origin != nil, self.wroteVideo else {
                    self.finishCompletion = nil
                    self.writer?.cancelWriting(); self.clear(); completion.finish(.success(false)); return
                }
                self.generation &+= 1; self.audioDrainScheduled = false
                self.video?.markAsFinished()
                self.finishAfterAudioDrain(endTime: endTime, completion: completion, generation: self.generation)
            }
        }
    }
    private func finishAfterAudioDrain(endTime: CMTime?, completion: CaptureCallback<Bool>, generation current: UInt64) {
        guard generation == current, !completion.isCancelled, let writer else { return }
        drainAudio()
        for backlog in audioBacklogs where backlog.samples.isEmpty && !backlog.finished {
            backlog.input.markAsFinished(); backlog.finished = true
            let timeline = backlog.timeline
            if timeline.clockFrames != 0 || timeline.silenceFrames != 0 || timeline.overlapFrames != 0 {
                Self.logger.info("Audio timeline sealed: clock frames=\(timeline.clockFrames, privacy: .public), silence frames=\(timeline.silenceFrames, privacy: .public), overlap frames=\(timeline.overlapFrames, privacy: .public)")
            }
        }
        if audioBacklogs.contains(where: { !$0.samples.isEmpty }) {
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
                self.finishAfterAudioDrain(endTime: endTime, completion: completion, generation: current)
            }
            return
        }
        if let endTime, let origin, endTime > origin, writer.status == .writing {
            writer.endSession(atSourceTime: endTime - origin)
        }
        writer.finishWriting {
            self.queue.async {
                guard self.generation == current else { return }
                let completed = self.writer?.status == .completed
                let failure = self.failure
                self.committedMedia = completed
                self.finishCompletion = nil
                self.clear()
                if let failure { completion.finish(.failure(failure)) }
                else if completed { completion.finish(.success(true)) }
                else { completion.finish(.failure(CaptureError.writerFailed)) }
            }
        }
    }
    func cancel(_ completion: CaptureCallback<Bool>? = nil) {
        queue.async {
            if let completion, self.finishCompletion !== completion { return }
            self.finishing = true
            self.committedMedia = false
            self.writer?.cancelWriting()
            self.clear()
        }
    }
    func abort() async {
        cancel()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    var hasCommittedMedia: Bool {
        get async {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.committedMedia) }
            }
        }
    }
    private func clear() {
        finishCompletion?.finish(.failure(CancellationError())); finishCompletion = nil
        generation &+= 1; audioDrainScheduled = false; audioBacklogs.removeAll()
        wroteVideo = false; writer = nil; video = nil; systemAudio = nil; microphone = nil; origin = nil
    }
}
