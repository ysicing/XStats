// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AudioDSP
import CoreAudio
import Testing

struct AudioDSPTests {
    @Test func accessProbeDiscardsInputAndNeverPlaysItBack() throws {
        let context = try #require(XSAccessProbeCreate())
        defer { XSAccessProbeDestroy(context) }
        #expect(!XSAccessProbeDidRun(context))
        var source: [Float] = [0.25, -0.5]
        var destination: [Float] = [99, 99]
        source.withUnsafeMutableBytes { inputBytes in
            destination.withUnsafeMutableBytes { outputBytes in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(inputBytes.count), mData: inputBytes.baseAddress))
                var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(outputBytes.count), mData: outputBytes.baseAddress))
                var timestamp = AudioTimeStamp()
                #expect(XSAccessProbeRead(0, &timestamp, &input, &timestamp, &output, &timestamp, UnsafeMutableRawPointer(context)) == noErr)
            }
        }
        #expect(XSAccessProbeDidRun(context))
        #expect(source == [0.25, -0.5])
        #expect(destination == [0, 0])
    }

    private func format(channels: UInt32 = 1, planar: Bool = false) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: planar ? 4 : channels * 4, mFramesPerPacket: 1, mBytesPerFrame: planar ? 4 : channels * 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    private func rendered(_ sources: [[Float]], configurations: [XSVolumeRoute],
                          destinationCount: Int = 1, finalGain: Float? = nil) throws -> [[Float]] {
        let context = try #require(configurations.withUnsafeBufferPointer { XSVolumeRendererCreate($0.baseAddress!, $0.count) })
        defer { XSVolumeRendererDestroy(context) }
        if let finalGain { XSVolumeRendererSetVolume(context, 0, finalGain) }
        let input = AudioBufferList.allocate(maximumBuffers: sources.count)
        let output = AudioBufferList.allocate(maximumBuffers: destinationCount)
        defer { input.unsafeMutablePointer.deallocate(); output.unsafeMutablePointer.deallocate() }
        var storage: [UnsafeMutablePointer<Float>] = []
        defer { for pointer in storage { pointer.deallocate() } }
        let channels = configurations[0].pcm.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            ? configurations[0].pcm.mChannelsPerFrame : 1
        for (index, samples) in sources.enumerated() {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            pointer.initialize(from: samples, count: samples.count)
            storage.append(pointer)
            input[index] = AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(samples.count * 4), mData: pointer)
        }
        let outputFormat = configurations[0].outputPCM.mFormatID == 0 ? configurations[0].pcm : configurations[0].outputPCM
        let outputChannels = outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : outputFormat.mChannelsPerFrame
        let count = sources[0].count / Int(channels) * Int(outputChannels)
        for index in 0..<destinationCount {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 99, count: count)
            storage.append(pointer)
            output[index] = AudioBuffer(mNumberChannels: outputChannels, mDataByteSize: UInt32(count * 4), mData: pointer)
        }
        var timestamp = AudioTimeStamp()
        _ = XSVolumeRender(0, &timestamp, input.unsafeMutablePointer, &timestamp, output.unsafeMutablePointer, &timestamp, UnsafeMutableRawPointer(context))
        return output.map { buffer in Array(UnsafeBufferPointer(start: buffer.mData!.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / 4)) }
    }

    private func configuration(gain: Float, channels: UInt32 = 1, planar: Bool = false, input: UInt32 = 0, output: UInt32 = 0) -> XSVolumeRoute {
        XSVolumeRoute(pcm: format(channels: channels, planar: planar), sourceBufferIndex: input,
            channelBufferCount: planar ? channels : 1, destinationBufferIndex: output, startingVolume: gain, outputPCM: AudioStreamBasicDescription())
    }

    private func renderedBytes(_ samples: [UInt8], pcm: AudioStreamBasicDescription, startingVolume: Float = 0.5) throws -> [UInt8] {
        var route = XSVolumeRoute(pcm: pcm, sourceBufferIndex: 0, channelBufferCount: 1, destinationBufferIndex: 0, startingVolume: startingVolume, outputPCM: AudioStreamBasicDescription())
        let context = try #require(XSVolumeRendererCreate(&route, 1))
        defer { XSVolumeRendererDestroy(context) }
        var source = samples
        var destination = [UInt8](repeating: 0xA5, count: samples.count)
        source.withUnsafeMutableBytes { inputBytes in
            destination.withUnsafeMutableBytes { outputBytes in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
                    mDataByteSize: UInt32(inputBytes.count), mData: inputBytes.baseAddress))
                var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
                    mDataByteSize: UInt32(outputBytes.count), mData: outputBytes.baseAddress))
                var timestamp = AudioTimeStamp()
                _ = XSVolumeRender(0, &timestamp, &input, &timestamp, &output, &timestamp, UnsafeMutableRawPointer(context))
            }
        }
        return destination
    }

    @Test(arguments: [32, 64])
    func mutedFloatingPCMDoesNotPropagateInvalidSourceSamples(_ bits: Int) throws {
        let values = bits == 32
            ? [Float.nan, Float.infinity].withUnsafeBytes { Array($0) }
            : [Double.nan, Double.infinity].withUnsafeBytes { Array($0) }
        let pcm = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(bits / 8),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(bits / 8), mChannelsPerFrame: 1, mBitsPerChannel: UInt32(bits), mReserved: 0)
        #expect(try renderedBytes(values, pcm: pcm, startingVolume: 0) == Array(repeating: 0, count: values.count))
    }

    @Test func float64PCMRetainsPrecisionAndSign() throws {
        let values: [Double] = [1, -0.5, 0.125]
        let pcm = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 1, mBitsPerChannel: 64, mReserved: 0)
        let output = try renderedBytes(values.withUnsafeBytes { Array($0) }, pcm: pcm)
        let actual = output.withUnsafeBytes { bytes in (0..<values.count).map { bytes.loadUnaligned(fromByteOffset: $0 * 8, as: Double.self) } }
        #expect(actual == [0.5, -0.25, 0.0625])
    }

    @Test(arguments: [16, 32])
    func integerPCMHandlesBothEndsOfTheSignedRange(_ bits: Int) throws {
        let values: [UInt8] = bits == 16
            ? [Int16.min, Int16.max].withUnsafeBytes { Array($0) }
            : [Int32.min, Int32.max].withUnsafeBytes { Array($0) }
        let pcm = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(bits / 8),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(bits / 8), mChannelsPerFrame: 1, mBitsPerChannel: UInt32(bits), mReserved: 0)
        let output = try renderedBytes(values, pcm: pcm)
        if bits == 16 {
            #expect(output.withUnsafeBytes { [$0.loadUnaligned(as: Int16.self), $0.loadUnaligned(fromByteOffset: 2, as: Int16.self)] } == [-16_384, 16_384])
        } else {
            #expect(output.withUnsafeBytes { [$0.loadUnaligned(as: Int32.self), $0.loadUnaligned(fromByteOffset: 4, as: Int32.self)] } == [-1_073_741_824, 1_073_741_824])
        }
    }

    @Test(arguments: [false, true])
    func packed24BitPCMHandlesBothByteOrders(_ bigEndian: Bool) throws {
        let samples: [[UInt8]] = [[0, 0, 128], [0, 0, 64]]
        let expected: [[UInt8]] = [[0, 0, 192], [0, 0, 32]]
        let pcm = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | (bigEndian ? kAudioFormatFlagIsBigEndian : 0),
            mBytesPerPacket: 3, mFramesPerPacket: 1, mBytesPerFrame: 3, mChannelsPerFrame: 1, mBitsPerChannel: 24, mReserved: 0)
        let output = try renderedBytes(samples.flatMap { bigEndian ? Array($0.reversed()) : $0 }, pcm: pcm)
        #expect(output == expected.flatMap { bigEndian ? Array($0.reversed()) : $0 })
    }

    @Test func attenuatesAndClearsPreviousOutputSamples() throws {
        #expect(try rendered([[1, -1, 0.5, -0.25]], configurations: [configuration(gain: 0.5)]) == [[0.5, -0.5, 0.25, -0.125]])
    }

    @Test func muteProducesSilence() throws {
        #expect(try rendered([[1, -1, 0.5, -0.25]], configurations: [configuration(gain: 0)]) == [[0, 0, 0, 0]])
    }

    @Test func unityAndInvalidGainsCannotAmplify() throws {
        for (gain, expected): (Float, [Float]) in [(1, [0.5, -0.25]), (.nan, [0, 0])] {
            #expect(try rendered([[0.5, -0.25]], configurations: [configuration(gain: gain)]) == [expected])
        }
    }

    @Test func boostRaisesQuietSamplesAndLimitsLoudPeaks() throws {
        #expect(try rendered([[0.1, -0.1, 0.2]], configurations: [configuration(gain: 2)]) == [[0.2, -0.2, 0.4]])
        let loud = try rendered([[1, -1, 0.1]], configurations: [configuration(gain: 2)])[0]
        #expect(loud.allSatisfy { abs($0) <= 0.98001 })
        #expect(abs(loud[0] - 0.98) < 0.00001)
        #expect(loud[2] > 0.09 && loud[2] < 0.11)
    }

    @Test func convertsStereoToMonoAndMonoToStereoWithoutChangingPlaybackSpeed() throws {
        var stereo = configuration(gain: 1, channels: 2)
        stereo.outputPCM = format(channels: 1)
        #expect(try rendered([[0.5, -0.5, 0.2, 0.4]], configurations: [stereo]) == [[0, 0.3]])
        var mono = configuration(gain: 1)
        mono.outputPCM = format(channels: 2)
        #expect(try rendered([[0.5, -0.5]], configurations: [mono]) == [[0.5, 0.5, -0.5, -0.5]])
    }
    @Test func boostLimiterPreservesStereoBalance() throws {
        let result = try rendered([[0.6, 0.2]], configurations: [configuration(gain: 2, channels: 2)])[0]
        #expect(abs(result[0] - 0.98) < 0.00001)
        #expect(abs(result[0] / result[1] - 3) < 0.00001)
    }
    @Test func frameCounterIgnoresMissingInputButCountsMutedPlayback() throws {
        var route = configuration(gain: 0)
        let context = try #require(XSVolumeRendererCreate(&route, 1))
        defer { XSVolumeRendererDestroy(context) }
        var samples: [Float] = [1, 1], destination: [Float] = [99, 99]
        samples.withUnsafeMutableBytes { source in
            destination.withUnsafeMutableBytes { target in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: nil))
                var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: target.baseAddress))
                var timestamp = AudioTimeStamp()
                _ = XSVolumeRender(0, &timestamp, &input, &timestamp, &output, &timestamp, UnsafeMutableRawPointer(context))
                #expect(XSVolumeRendererFrameCount(context) == 0)
                input.mBuffers.mData = source.baseAddress
                _ = XSVolumeRender(0, &timestamp, &input, &timestamp, &output, &timestamp, UnsafeMutableRawPointer(context))
                #expect(XSVolumeRendererFrameCount(context) == 2)
            }
        }
        #expect(destination == [0, 0])
    }

    @Test func limitingReturnsToTheFastPathAfterBoostIsRemoved() throws {
        var route = configuration(gain: 2)
        let context = try #require(XSVolumeRendererCreate(&route, 1))
        defer { XSVolumeRendererDestroy(context) }
        var source = Array(repeating: Float(1), count: 512), destination = Array(repeating: Float(0), count: 512)
        source.withUnsafeMutableBytes { inputBytes in
            destination.withUnsafeMutableBytes { outputBytes in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: inputBytes.baseAddress))
                var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: outputBytes.baseAddress))
                var timestamp = AudioTimeStamp()
                _ = XSVolumeRender(0, &timestamp, &input, &timestamp, &output, &timestamp, UnsafeMutableRawPointer(context))
                #expect(XSVolumeRendererFastFrameCount(context) == 0)
                XSVolumeRendererSetVolume(context, 0, 0.5)
                // 超过 3 秒的持续音频；只检查执行路径计数，不依赖机器运行速度。
                for _ in 0..<300 {
                    _ = XSVolumeRender(0, &timestamp, &input, &timestamp, &output, &timestamp, UnsafeMutableRawPointer(context))
                }
                #expect(XSVolumeRendererFastFrameCount(context) > 0)
            }
        }
        #expect(destination.allSatisfy { $0 == 0.5 })
    }

    @Test func independentAppGainsAreSummedIntoTheSameOutput() throws {
        let configurations = [configuration(gain: 0.5), configuration(gain: 0.25, input: 1)]
        #expect(try rendered([[0.4, -0.4], [0.8, 0.8]], configurations: configurations) == [[0.4, 0]])
    }

    @Test func stereoKeepsChannelOrder() throws {
        #expect(try rendered([[1, -1, 0.2, 0.4]], configurations: [configuration(gain: 0.5, channels: 2)]) == [[0.5, -0.5, 0.1, 0.2]])
    }

    @Test func planarStreamsKeepSeparateChannelsAndHonorOutputOffset() throws {
        let configuration = configuration(gain: 0.5, channels: 2, planar: true, output: 1)
        #expect(try rendered([[1, 0.2], [-1, 0.4]], configurations: [configuration], destinationCount: 3) == [[0, 0], [0.5, 0.1], [-0.5, 0.2]])
    }

    @Test func duplexHardwareInputIsSkippedRatherThanMixedBackToOutput() throws {
        #expect(try rendered([[1, 1], [0.2, 0.4]], configurations: [configuration(gain: 0.5, input: 1)]) == [[0.1, 0.2]])
    }

    @Test func absentInputBufferProducesSilenceWithoutReadingPastTheList() throws {
        #expect(try rendered([[1, 1]], configurations: [configuration(gain: 0.5, input: 8)]) == [[0, 0]])
    }

    @Test func gainChangesRampInsteadOfJumpingAtTheFirstSample() throws {
        let output = try rendered([Array(repeating: 1, count: 2_000)], configurations: [configuration(gain: 1)], finalGain: 0)[0]
        #expect(output.first == 1)
        #expect(output[960] > 0.49 && output[960] < 0.51)
        #expect(output[1_920] == 0)
        #expect(output.last == 0)
    }

    @Test(arguments: [false, true])
    func signed24BitSamplesIn32BitContainersKeepTheirSign(_ bigEndian: Bool) throws {
        let flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh | (bigEndian ? kAudioFormatFlagIsBigEndian : 0)
        let format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 24, mReserved: 0)
        var configuration = XSVolumeRoute(pcm: format, sourceBufferIndex: 0, channelBufferCount: 1,
            destinationBufferIndex: 0, startingVolume: 0.5, outputPCM: AudioStreamBasicDescription())
        let context = try #require(XSVolumeRendererCreate(&configuration, 1))
        defer { XSVolumeRendererDestroy(context) }
        var samples: [UInt32] = [UInt32(0x80000000), UInt32(0x40000000)].map { bigEndian ? $0.bigEndian : $0.littleEndian }
        var destination = [UInt32](repeating: 0, count: 2)
        samples.withUnsafeMutableBytes { inputBytes in
            destination.withUnsafeMutableBytes { outputBytes in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: inputBytes.baseAddress))
                var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: outputBytes.baseAddress))
                var timestamp = AudioTimeStamp()
                _ = XSVolumeRender(0, &timestamp, &input, &timestamp, &output, &timestamp, UnsafeMutableRawPointer(context))
            }
        }
        #expect(destination.map { bigEndian ? UInt32(bigEndian: $0) : UInt32(littleEndian: $0) } == [0xC0000000, 0x20000000])
    }
}
