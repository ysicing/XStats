// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import Foundation
import os
@preconcurrency import AVFoundation
@testable import CaptureCore

@Suite struct RecordingExportTests {
    private func video(time: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, 128, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
        let description = try #require(format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
    private func audio(time: Double, channels: UInt32, frequency: Double) throws -> CMSampleBuffer {
        let frames = 1600
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
        let data = (0..<frames * Int(channels)).map { i in Float(sin(Double(i / Int(channels)) / 48000 * frequency * 2 * .pi) * 0.1) }
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count * 4, flags: 0, blockBufferOut: &block) == noErr)
        let dataBlock = try #require(block)
        data.withUnsafeBytes { bytes in #expect(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: dataBlock, offsetIntoDestination: 0, dataLength: bytes.count) == noErr) }
        let audioFormat = try #require(format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: dataBlock, formatDescription: audioFormat, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
    private func segment(_ media: RecordingMedia, origin: Double, system: Bool, microphone: Bool) async throws -> URL {
        let url = media.newSegmentURL()
        let writer = RecordingWriter { _ in }
        var options = RecordingOptions(); options.systemAudio = system; options.microphone = microphone
        try await writer.prepare(url: url, size: CGSize(width: 64, height: 48), options: options)
        for frame in 0..<30 {
            let time = origin + Double(frame) / 30
            let video = try video(time: time)
            let systemSample = system ? try audio(time: time, channels: 2, frequency: 440) : nil
            let microphoneSample = microphone ? try audio(time: time, channels: 1, frequency: 880) : nil
            writer.queue.sync {
                writer.consumeVideo(video)
                if let systemSample { writer.consumeAudio(systemSample, microphone: false) }
                if let microphoneSample { writer.consumeAudio(microphoneSample, microphone: true) }
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(try await writer.finish())
        return url
    }
    @Test func mediaFailureReportsOnceAndStopsAfterFinish() async throws {
        let media = try RecordingMedia()
        defer { try? media.discard() }
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let writer = RecordingWriter { _ in failures.withLock { $0 += 1 } }
        var options = RecordingOptions(); options.systemAudio = false
        try await writer.prepare(url: media.newSegmentURL(), size: CGSize(width: 64, height: 48), options: options)
        writer.reportAudioFailure(); writer.reportAudioFailure()
        #expect(try await !writer.finish())
        writer.reportAudioFailure()
        writer.queue.sync {}
        #expect(failures.withLock { $0 } == 1)
    }
    @Test @MainActor func staticFrameKeepsProducerDuration() async throws {
        let media = try RecordingMedia()
        defer { try? media.discard() }
        let url = media.newSegmentURL()
        let writer = RecordingWriter { _ in }
        var options = RecordingOptions(); options.systemAudio = false
        try await writer.prepare(url: url, size: CGSize(width: 64, height: 48), options: options)
        let sample = try video(time: 100)
        writer.queue.sync { writer.consumeVideo(sample) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await writer.finish(endTime: CMTime(seconds: 102, preferredTimescale: 48000)))
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        #expect(abs(try await track.load(.timeRange).duration.seconds - 2) < 0.1)
    }
    @Test @MainActor func pauseSegmentsTrimAndMixToSingleAudioTrack() async throws {
        let media = try RecordingMedia()
        defer { try? media.discard() }
        let first = try await segment(media, origin: 100, system: true, microphone: true)
        let second = try await segment(media, origin: 120, system: true, microphone: true)
        let output = media.directory.appendingPathComponent("output.mp4")
        let exporter = RecordingExporter()
        let composition = try await exporter.composition(segments: [first, second])
        let duration = try await composition.load(.duration).seconds
        #expect(abs(duration - 2) < 0.15)
        try await exporter.export(segments: [first, second], trim: RecordingTrim(start: 0.25, end: 1.75, duration: duration), to: output)
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 1.5) < 0.1)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(CMFormatDescriptionGetMediaSubType(try #require(try await audio.load(.formatDescriptions).first)) == kAudioFormatMPEG4AAC)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let formats = try await video.load(.formatDescriptions)
        #expect(CMFormatDescriptionGetMediaSubType(try #require(formats.first)) == kCMVideoCodecType_H264)
    }
    @Test @MainActor func cancelledExportPreservesOriginalAndExistingDestination() async throws {
        let media = try RecordingMedia()
        defer { try? media.discard() }
        let source = try await segment(media, origin: 100, system: true, microphone: false)
        let output = media.directory.appendingPathComponent("existing.mp4")
        let sentinel = Data("existing destination".utf8)
        try sentinel.write(to: output)
        let exporter = RecordingExporter()
        let task = Task { try await exporter.export(segments: [source], trim: nil, to: output) }
        await Task.yield()
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try Data(contentsOf: output) == sentinel)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: media.directory.path).filter { $0.hasPrefix(".") }.isEmpty)
    }
    @Test @MainActor func failedSaveAllowsRetryAndLeavesSource() async throws {
        let media = try RecordingMedia()
        defer { try? media.discard() }
        let source = try await segment(media, origin: 100, system: false, microphone: false)
        let exporter = RecordingExporter()
        await #expect(throws: (any Error).self) {
            try await exporter.export(segments: [source], trim: nil, to: media.directory.appendingPathComponent("missing/output.mp4"))
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        let output = media.directory.appendingPathComponent("retry.mp4")
        try await exporter.export(segments: [source], trim: nil, to: output)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
    @Test(arguments: [(false, false), (true, false), (false, true)]) @MainActor
    func audioOptionsProduceExpectedTracks(options: (Bool, Bool)) async throws {
        let media = try RecordingMedia()
        defer { try? media.discard() }
        let url = try await segment(media, origin: 100, system: options.0, microphone: options.1)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        #expect(tracks.count == (options.0 || options.1 ? 1 : 0))
    }
}
