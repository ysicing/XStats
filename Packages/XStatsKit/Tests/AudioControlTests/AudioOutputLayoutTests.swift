// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreAudio
import Testing
@testable import AudioControl

struct AudioOutputLayoutTests {
    private func stream(start: UInt32, channels: UInt32, buffer: UInt32 = 0) -> AudioOutputStream {
        let format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        return AudioOutputStream(startingChannel: start, bufferIndex: buffer, format: format)
    }

    @Test func usesPreferredStereoChannelsWithinAMultichannelStream() throws {
        let layout = try AudioOutputLayout.resolve(streams: [stream(start: 1, channels: 8)], preferred: [3,4])
        #expect(layout.leftChannel == 3)
        #expect(layout.rightChannel == 4)
    }

    @Test func convertsDeviceChannelNumbersToTheSelectedStreamsLocalChannels() throws {
        let layout = try AudioOutputLayout.resolve(streams: [stream(start: 1, channels: 2), stream(start: 3, channels: 8, buffer: 1)], preferred: [6,5])
        #expect(layout.bufferIndex == 1)
        #expect(layout.leftChannel == 4)
        #expect(layout.rightChannel == 3)
    }

    @Test func rejectsPreferredChannelsThatCrossSeparateStreams() throws {
        #expect(throws: AudioControlError.unsupportedFormat) {
            try AudioOutputLayout.resolve(streams: [stream(start: 1, channels: 2), stream(start: 3, channels: 2, buffer: 1)], preferred: [2,3])
        }
    }

    @Test func missingPreferenceSupportsOnlyAnUnambiguousMonoOrStereoOutput() throws {
        let stereo = try AudioOutputLayout.resolve(streams: [stream(start: 1, channels: 2)], preferred: nil)
        #expect(stereo.leftChannel == 1 && stereo.rightChannel == 2)
        let mono = try AudioOutputLayout.resolve(streams: [stream(start: 1, channels: 1)], preferred: nil)
        #expect(mono.leftChannel == 0 && mono.rightChannel == 0)
        #expect(throws: AudioControlError.unsupportedFormat) {
            try AudioOutputLayout.resolve(streams: [stream(start: 1, channels: 8)], preferred: nil)
        }
    }
}
