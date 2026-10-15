// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
@preconcurrency import AVFoundation
@testable import CaptureCore

@Suite struct RecordingAudioTimelineTests {
    private func sample(time: Double, frames: Int = 1024, rate: Double = 48000, planar: Bool = false,
                        commonFormat: AVAudioCommonFormat = .pcmFormatFloat32) throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(commonFormat: commonFormat, sampleRate: rate, channels: 2, interleaved: !planar))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for index in buffers.indices {
            if commonFormat != .pcmFormatFloat32 {
                memset(try #require(buffers[index].mData), 0, Int(buffers[index].mDataByteSize))
                continue
            }
            let values = try #require(buffers[index].mData).assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                if planar { values[frame] = index == 0 ? 0.25 : -0.75 }
                else { values[frame * 2] = 0.25; values[frame * 2 + 1] = -0.75 }
            }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr)
        let output = try #require(result)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(output, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        #expect(CMSampleBufferSetDataReady(output) == noErr)
        return output
    }
    private func values(_ sample: CMSampleBuffer) throws -> [Float] {
        let frames = CMSampleBufferGetNumSamples(sample)
        let format = AVAudioFormat(cmAudioFormatDescription: try #require(CMSampleBufferGetFormatDescription(sample)))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        #expect(CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr)
        let data = try #require(buffer.audioBufferList.pointee.mBuffers.mData).assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: data, count: frames * 2))
    }
    @Test(arguments: [-341.0, 341.0]) func sourceClockDriftKeepsAbsoluteTimeline(ppm: Double) throws {
        let timeline = RecordingAudioTimeline()
        var end = 0.0
        // Five source minutes at both clock rates; no wall-clock waiting.
        let count = 14063
        for index in 0..<count {
            let time = 0.125 + Double(index * 1024) / 48000 * (1 + ppm / 1_000_000)
            let output = try timeline.normalize(sample(time: time))
            let last = try #require(output.last)
            end = CMSampleBufferGetPresentationTimeStamp(last).seconds + Double(CMSampleBufferGetNumSamples(last)) / 48000
            if index == 0 { #expect(abs(CMSampleBufferGetPresentationTimeStamp(last).seconds - 0.125) < 0.000001) }
        }
        let expected = 0.125 + Double((count - 1) * 1024) / 48000 * (1 + ppm / 1_000_000) + 1024.0 / 48000
        #expect(abs(end - expected) <= 1.0 / 48000)
        #expect(abs(timeline.clockFrames) > 4000)
        #expect(timeline.silenceFrames == 0)
        #expect(timeline.overlapFrames == 0)
    }
    @Test func planarInputPreservesBothChannelsAndActualSampleRate() throws {
        let timeline = RecordingAudioTimeline()
        _ = try timeline.normalize(sample(time: 0.25, rate: 44100, planar: true))
        let output = try timeline.normalize(sample(time: 0.25 + 1025.0 / 44100, rate: 44100, planar: true))
        let corrected = try #require(output.last)
        #expect(CMSampleBufferGetNumSamples(corrected) == 1025)
        let data = try values(corrected)
        #expect(stride(from: 0, to: data.count, by: 2).allSatisfy { abs(data[$0] - 0.25) < 0.000001 })
        #expect(stride(from: 1, to: data.count, by: 2).allSatisfy { abs(data[$0] + 0.75) < 0.000001 })
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(corrected).seconds - (0.25 + 1024.0 / 44100)) < 0.000001)
    }
    @Test func gapsContainRealSilenceAndOverlapsDoNotReplaySound() throws {
        let timeline = RecordingAudioTimeline()
        _ = try timeline.normalize(sample(time: 0, frames: 480))
        let afterGap = try timeline.normalize(sample(time: 0.02, frames: 480))
        #expect(afterGap.count == 2)
        #expect(try values(try #require(afterGap.first)).allSatisfy { $0 == 0 })
        #expect(timeline.silenceFrames == 480)
        let overlap = try timeline.normalize(sample(time: 0.025, frames: 480))
        #expect(CMSampleBufferGetNumSamples(try #require(overlap.last)) == 240)
        #expect(timeline.overlapFrames == 240)
        #expect(try timeline.normalize(sample(time: 0.025, frames: 16)).isEmpty)
        #expect(timeline.overlapFrames == 256)
    }
    @Test func smallTimestampJumpDoesNotCauseLargeInstantaneousResampling() throws {
        let timeline = RecordingAudioTimeline()
        _ = try timeline.normalize(sample(time: 0))
        let output = try timeline.normalize(sample(time: 1120.0 / 48000))
        #expect(output.count == 2)
        #expect(timeline.clockFrames == 0)
        #expect(timeline.silenceFrames == 96)
    }
    @Test func excessiveGapAndFormatChangeFailBeforeLargeAllocation() throws {
        let timeline = RecordingAudioTimeline()
        _ = try timeline.normalize(sample(time: 0))
        #expect(throws: CaptureError.writerFailed) { try timeline.normalize(sample(time: 10)) }
        #expect(throws: CaptureError.writerFailed) { try timeline.normalize(sample(time: 0.03, rate: 44100)) }
    }
    @Test func fractionalRateAndOversizedSourceFormatAreRejected() throws {
        #expect(throws: CaptureError.writerFailed) { try RecordingAudioTimeline().normalize(sample(time: 0, rate: 8000.5)) }
        #expect(throws: CaptureError.writerFailed) {
            try RecordingAudioTimeline().normalize(sample(time: 0, frames: 524288, commonFormat: .pcmFormatFloat64))
        }
        #expect(throws: CaptureError.writerFailed) {
            try RecordingAudioTimeline().normalize(sample(time: 0, frames: 524288, planar: true, commonFormat: .pcmFormatFloat64))
        }
    }
}
