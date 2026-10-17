// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import Foundation
import os
@preconcurrency import AVFoundation
import ScreenCaptureKit
@testable import CaptureCore

@Suite struct RecordingExportTests {
  private func video(time: Double) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    #expect(
      CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixel)
        == kCVReturnSuccess)
    let buffer = try #require(pixel)
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      memset(base, 128, CVPixelBufferGetDataSize(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    var format: CMVideoFormatDescription?
    #expect(
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr
    )
    let description = try #require(format)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: description,
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
  }
  private func audio(time: Double, channels: UInt32, frequency: Double) throws -> CMSampleBuffer {
    let frames = 1600
    var description = AudioStreamBasicDescription(
      mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
      mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    #expect(
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        == noErr)
    let data = (0..<frames * Int(channels)).map { i in
      Float(sin(Double(i / Int(channels)) / 48000 * frequency * 2 * .pi) * 0.1)
    }
    var block: CMBlockBuffer?
    #expect(
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count * 4,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: data.count * 4, flags: 0, blockBufferOut: &block) == noErr)
    let dataBlock = try #require(block)
    data.withUnsafeBytes { bytes in
      #expect(
        CMBlockBufferReplaceDataBytes(
          with: bytes.baseAddress!, blockBuffer: dataBlock, offsetIntoDestination: 0,
          dataLength: bytes.count) == noErr)
    }
    let audioFormat = try #require(format)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48000),
      presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: dataBlock, formatDescription: audioFormat,
        sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
  }
  private func segment(_ media: RecordingMedia, origin: Double, system: Bool, microphone: Bool)
    async throws -> URL
  {
    let url = media.newSegmentURL()
    let writer = RecordingWriter { _ in }
    var options = RecordingOptions()
    options.systemAudio = system
    options.microphone = microphone
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
  @Test func noCommittedVideoDoesNotProduceARecoverableSegment() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let writer = RecordingWriter(isReady: { _ in false }) { _ in }
    let url = media.newSegmentURL()
    try await writer.prepare(
      url: url, size: CGSize(width: 64, height: 48), options: RecordingOptions())
    let frame = try video(time: 100)
    writer.queue.sync { writer.consumeVideo(frame) }
    #expect(try await !writer.finish())
  }
  @Test @MainActor func transientAudioBackpressureBuffersSamplesAndRecordingContinues() async throws
  {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let blocked = OSAllocatedUnfairLock(initialState: true)
    let failures = OSAllocatedUnfairLock(initialState: 0)
    let writer = RecordingWriter(isReady: { input in
      if input.mediaType == .audio, blocked.withLock({ $0 }) { return false }
      return input.isReadyForMoreMediaData
    }) { _ in failures.withLock { $0 += 1 } }
    let url = media.newSegmentURL()
    var options = RecordingOptions()
    options.microphone = true
    try await writer.prepare(url: url, size: CGSize(width: 64, height: 48), options: options)
    for frame in 0..<30 {
      let time = 100 + Double(frame) / 30
      let video = try video(time: time)
      let system = try audio(time: time, channels: 2, frequency: 440)
      let microphone = try audio(time: time, channels: 1, frequency: 880)
      writer.queue.sync {
        writer.consumeVideo(video)
        writer.consumeAudio(system, microphone: false)
        writer.consumeAudio(microphone, microphone: true)
      }
      if frame == 5 { blocked.withLock { $0 = false } }
      try await Task.sleep(for: .milliseconds(15))
    }
    #expect(try await writer.finish())
    #expect(failures.withLock { $0 } == 0)
    #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count == 2)
    #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).count == 1)
  }
  @Test func audioBackpressureKeepsLaterSamplesOnTheVideoTimeline() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let blocked = OSAllocatedUnfairLock(initialState: false)
    let writer = RecordingWriter(isReady: { input in
      if input.mediaType == .audio, blocked.withLock({ $0 }) { return false }
      return input.isReadyForMoreMediaData
    }) { _ in }
    let url = media.newSegmentURL()
    try await writer.prepare(
      url: url, size: CGSize(width: 64, height: 48), options: RecordingOptions())
    for frame in 0..<60 {
      blocked.withLock { $0 = (15..<30).contains(frame) }
      let time = 100 + Double(frame) / 30
      let picture = try video(time: time)
      let sound = try audio(time: time, channels: 2, frequency: 440)
      writer.queue.sync {
        writer.consumeVideo(picture)
        writer.consumeAudio(sound, microphone: false)
      }
      try await Task.sleep(for: .milliseconds(15))
    }
    #expect(try await writer.finish())
    let asset = AVURLAsset(url: url)
    let sound = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let picture = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let audioEnd = try await sound.load(.timeRange).end.seconds
    let videoEnd = try await picture.load(.timeRange).end.seconds
    #expect(abs(audioEnd - videoEnd) < 0.1)
  }
  @Test @MainActor func producerAudioTimestampGapsDoNotMoveLaterSoundEarlier() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let url = media.newSegmentURL()
    let writer = RecordingWriter { _ in }
    try await writer.prepare(
      url: url, size: CGSize(width: 64, height: 48), options: RecordingOptions())
    for frame in 0..<60 {
      let time = 100 + Double(frame) / 30
      let picture = try video(time: time)
      let sound =
        (15..<30).contains(frame) ? nil : try audio(time: time, channels: 2, frequency: 440)
      writer.queue.sync {
        writer.consumeVideo(picture)
        if let sound { writer.consumeAudio(sound, microphone: false) }
      }
      try await Task.sleep(for: .milliseconds(15))
    }
    #expect(try await writer.finish())
    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
    #expect(abs(try await track.load(.timeRange).end.seconds - 2) < 0.1)
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    try await RecordingExporter().export(segments: [url], trim: nil, to: output)
    let asset = AVURLAsset(url: output)
    let exportedTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let decoded = AVAssetReaderTrackOutput(
      track: exportedTrack,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
      ])
    reader.add(decoded)
    #expect(reader.startReading())
    var gapEnergy = 0.0
    var markerEnergy = 0.0
    var gapCount = 0
    var markerCount = 0
    while let sample = decoded.copyNextSampleBuffer() {
      let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      let count = CMBlockBufferGetDataLength(block) / 4
      var values = [Float](repeating: 0, count: count)
      let status = values.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(
          block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
      }
      #expect(status == noErr)
      for index in values.indices {
        let position = time + Double(index / 2) / 48000
        if (0.65..<0.85).contains(position) {
          gapEnergy += Double(values[index] * values[index])
          gapCount += 1
        }
        if (1.1..<1.3).contains(position) {
          markerEnergy += Double(values[index] * values[index])
          markerCount += 1
        }
      }
    }
    #expect(reader.status == .completed)
    #expect(gapCount > 1000 && markerCount > 1000)
    #expect(sqrt(gapEnergy / Double(max(1, gapCount))) < 0.001)
    #expect(sqrt(markerEnergy / Double(max(1, markerCount))) > 0.04)
  }
  @Test func cancelledFinishStopsWriterWithoutReportingMediaFailure() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let failures = OSAllocatedUnfairLock(initialState: 0)
    let writer = RecordingWriter { _ in failures.withLock { $0 += 1 } }
    var options = RecordingOptions()
    options.systemAudio = false
    try await writer.prepare(
      url: media.newSegmentURL(), size: CGSize(width: 64, height: 48), options: options)
    let sample = try video(time: 100)
    writer.queue.sync { writer.consumeVideo(sample) }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await writer.finish()
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    await writer.abort()
    writer.reportAudioFailure()
    writer.queue.sync { writer.consumeVideo(sample) }
    #expect(failures.withLock { $0 } == 0)
    #expect(try await !writer.finish())
  }
  @Test func stoppingDrainsBlockedMicrophoneAfterOtherInputsFinish() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let blocked = OSAllocatedUnfairLock(initialState: false)
    let failures = OSAllocatedUnfairLock(initialState: 0)
    let writer = RecordingWriter(isReady: { input in
      if input.mediaType == .audio, input.outputSettings?[AVNumberOfChannelsKey] as? Int == 1,
        blocked.withLock({ $0 })
      {
        return false
      }
      return input.isReadyForMoreMediaData
    }) { _ in failures.withLock { $0 += 1 } }
    var options = RecordingOptions()
    options.microphone = true
    let url = media.newSegmentURL()
    try await writer.prepare(url: url, size: CGSize(width: 64, height: 48), options: options)
    for frame in 0..<30 {
      blocked.withLock { $0 = frame >= 24 }
      let time = 100 + Double(frame) / 30
      let picture = try video(time: time)
      let system = try audio(time: time, channels: 2, frequency: 440)
      let mic = try audio(time: time, channels: 1, frequency: 880)
      writer.queue.sync {
        writer.consumeVideo(picture)
        writer.consumeAudio(system, microphone: false)
        writer.consumeAudio(mic, microphone: true)
      }
      try await Task.sleep(for: .milliseconds(15))
    }
    let release = Task {
      try await Task.sleep(for: .milliseconds(100))
      blocked.withLock { $0 = false }
    }
    #expect(try await writer.finish())
    try await release.value
    #expect(failures.withLock { $0 } == 0)
    let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
    #expect(tracks.count == 2)
    for track in tracks { #expect(abs(try await track.load(.timeRange).end.seconds - 1) < 0.1) }
  }
  @Test(arguments: [false, true])
  func sustainedAudioBackpressureStopsInsteadOfCompressingTheTimeline(_ overflow: Bool) async throws
  {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let failures = OSAllocatedUnfairLock(initialState: 0)
    let writer = RecordingWriter(isReady: { input in
      input.mediaType == .video && input.isReadyForMoreMediaData
    }) { _ in failures.withLock { $0 += 1 } }
    try await writer.prepare(
      url: media.newSegmentURL(), size: CGSize(width: 64, height: 48), options: RecordingOptions())
    let picture = try video(time: 100)
    writer.queue.sync { writer.consumeVideo(picture) }
    for frame in 0..<(overflow ? 70 : 2) {
      let sound = try audio(time: 100 + Double(frame) / 30, channels: 2, frequency: 440)
      writer.queue.sync { writer.consumeAudio(sound, microphone: false) }
    }
    if overflow { #expect(failures.withLock { $0 } == 1) }
    await #expect(throws: CaptureError.writerFailed) { try await writer.finish() }
    #expect(await writer.hasCommittedMedia)
    #expect(failures.withLock { $0 } == 1)
    await writer.abort()
  }
  @Test(arguments: [false, true])
  func cancellationWhileDrainingAudioReleasesPendingWorkWithoutFailure(_ cancelTask: Bool)
    async throws
  {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let failures = OSAllocatedUnfairLock(initialState: 0)
    let writer = RecordingWriter(isReady: { input in
      input.mediaType == .video && input.isReadyForMoreMediaData
    }) { _ in failures.withLock { $0 += 1 } }
    try await writer.prepare(
      url: media.newSegmentURL(), size: CGSize(width: 64, height: 48), options: RecordingOptions())
    let picture = try video(time: 100)
    let sound = try audio(time: 100, channels: 2, frequency: 440)
    writer.queue.sync {
      writer.consumeVideo(picture)
      writer.consumeAudio(sound, microphone: false)
    }
    let finishing = Task { try await writer.finish() }
    try await Task.sleep(for: .milliseconds(30))
    if cancelTask { finishing.cancel() } else { await writer.abort() }
    await #expect(throws: CancellationError.self) { try await finishing.value }
    await writer.abort()
    try await Task.sleep(for: .milliseconds(1_100))
    #expect(failures.withLock { $0 } == 0)
    #expect(try await !writer.finish())
  }
  @Test func cancellingDuplicateFinishDoesNotCancelTheActiveFinish() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let blocked = OSAllocatedUnfairLock(initialState: true)
    let writer = RecordingWriter(isReady: { input in
      if input.mediaType == .audio, blocked.withLock({ $0 }) { return false }
      return input.isReadyForMoreMediaData
    }) { _ in Issue.record("Cancelling a duplicate finish must not fail the active recording") }
    try await writer.prepare(
      url: media.newSegmentURL(), size: CGSize(width: 64, height: 48), options: RecordingOptions())
    let picture = try video(time: 100)
    let sound = try audio(time: 100, channels: 2, frequency: 440)
    writer.queue.sync {
      writer.consumeVideo(picture)
      writer.consumeAudio(sound, microphone: false)
    }
    let finishing = Task { try await writer.finish() }
    try await Task.sleep(for: .milliseconds(30))
    let duplicate = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await writer.finish()
    }
    await #expect(throws: CancellationError.self) { try await duplicate.value }
    blocked.withLock { $0 = false }
    #expect(try await finishing.value)
    #expect(await writer.hasCommittedMedia)
  }
  @Test func fullAudioBacklogCanRecoverBeforeTheNextSampleArrives() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let blocked = OSAllocatedUnfairLock(initialState: true)
    let failures = OSAllocatedUnfairLock(initialState: 0)
    let writer = RecordingWriter(isReady: { input in
      if input.mediaType == .audio, blocked.withLock({ $0 }) { return false }
      return input.isReadyForMoreMediaData
    }) { _ in failures.withLock { $0 += 1 } }
    let url = media.newSegmentURL()
    try await writer.prepare(
      url: url, size: CGSize(width: 64, height: 48), options: RecordingOptions())
    let picture = try video(time: 100)
    writer.queue.sync { writer.consumeVideo(picture) }
    for frame in 0..<65 {
      if frame == 64 { blocked.withLock { $0 = false } }
      let sound = try audio(time: 100 + Double(frame) / 30, channels: 2, frequency: 440)
      writer.queue.sync { writer.consumeAudio(sound, microphone: false) }
    }
    #expect(
      try await writer.finish(endTime: CMTime(seconds: 100 + 65.0 / 30, preferredTimescale: 48000)))
    #expect(failures.withLock { $0 } == 0)
    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
    #expect(abs(try await track.load(.timeRange).end.seconds - 65.0 / 30) < 0.1)
  }
  @Test func mediaFailureReportsOnceAndStopsAfterFinish() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let failures = OSAllocatedUnfairLock(initialState: 0)
    let writer = RecordingWriter { _ in failures.withLock { $0 += 1 } }
    var options = RecordingOptions()
    options.systemAudio = false
    try await writer.prepare(
      url: media.newSegmentURL(), size: CGSize(width: 64, height: 48), options: options)
    writer.reportAudioFailure()
    writer.reportAudioFailure()
    #expect(try await !writer.finish())
    writer.reportAudioFailure()
    writer.queue.sync {}
    #expect(failures.withLock { $0 } == 1)
  }
  @Test func microphoneFailureKeepsItsMeaningAndReportsOnlyOnce() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let failures = OSAllocatedUnfairLock(initialState: [CaptureError]())
    let writer = RecordingWriter { failure in failures.withLock { $0.append(failure) } }
    try await writer.prepare(
      url: media.newSegmentURL(), size: CGSize(width: 64, height: 48), options: RecordingOptions())
    writer.reportAudioFailure(.microphonePermission)
    writer.reportAudioFailure(.microphoneFailed)
    writer.queue.sync {}
    #expect(failures.withLock { $0 } == [.microphonePermission])
    await writer.abort()
    writer.reportAudioFailure(.microphoneFailed)
    writer.queue.sync {}
    #expect(failures.withLock { $0.count } == 1)
  }
  @Test @MainActor func staticFrameKeepsProducerDuration() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let url = media.newSegmentURL()
    let writer = RecordingWriter { _ in }
    var options = RecordingOptions()
    options.systemAudio = false
    try await writer.prepare(url: url, size: CGSize(width: 64, height: 48), options: options)
    let sample = try video(time: 100)
    writer.queue.sync { writer.consumeVideo(sample) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await writer.finish(endTime: CMTime(seconds: 102, preferredTimescale: 48000)))
    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
    #expect(abs(try await track.load(.timeRange).duration.seconds - 2) < 0.1)
  }
  @Test @MainActor func confirmedStreamFailureStillFinishesTheCurrentSegment() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let url = media.newSegmentURL()
    let writer = RecordingWriter { _ in }
    var options = RecordingOptions()
    options.systemAudio = false
    try await writer.prepare(url: url, size: CGSize(width: 64, height: 48), options: options)
    let sample = try video(time: CMClockGetTime(CMClockGetHostTimeClock()).seconds - 0.1)
    writer.queue.sync { writer.consumeVideo(sample) }
    let stream = SCStream(
      filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
    let recorder = ScreenRecorder(media: media, stream: stream, writer: writer, activeURL: url) {
      _ in
      Issue.record("delegate 已确认停止，不应再次调用停止 API")
    }
    let (failures, continuation) = AsyncStream<CaptureError>.makeStream()
    recorder.onFailure = { continuation.yield($0) }
    var iterator = failures.makeAsyncIterator()
    recorder.stream(
      stream,
      didStopWithError: NSError(
        domain: SCStreamErrorDomain, code: SCStreamError.Code.internalError.rawValue))
    #expect(await iterator.next() == .captureFailed)
    #expect(!recorder.isCapturing)
    try await recorder.stop()
    #expect(recorder.segments == [url])
    #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).count == 1)
    continuation.finish()
  }
  @Test @MainActor func audioFailureRetainsTheSealedSegmentAndReportsTheError() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let url = media.newSegmentURL()
    let writer = RecordingWriter(isReady: { input in
      input.mediaType == .video && input.isReadyForMoreMediaData
    }) { _ in }
    try await writer.prepare(
      url: url, size: CGSize(width: 64, height: 48), options: RecordingOptions())
    let time = CMClockGetTime(CMClockGetHostTimeClock()).seconds - 0.1
    let picture = try video(time: time)
    let sound = try audio(time: time, channels: 2, frequency: 440)
    writer.queue.sync {
      writer.consumeVideo(picture)
      writer.consumeAudio(sound, microphone: false)
    }
    let stream = SCStream(
      filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
    let recorder = ScreenRecorder(media: media, stream: stream, writer: writer, activeURL: url) {
      _ in
    }
    await #expect(throws: CaptureError.writerFailed) { try await recorder.stop() }
    #expect(!recorder.isCapturing)
    #expect(recorder.segments == [url])
    #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).count == 1)
  }
  /// writer 失败且没有任何可封存的媒体时，残缺文件不可播放，必须随失败一并清理，
  /// 否则磁盘写满这类失败会让半成品继续占用空间，直到下次启动的过期清理。
  @Test @MainActor func failedFinishWithoutSealedMediaRemovesTheUnplayableSegment() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let url = media.newSegmentURL()
    let writer = RecordingWriter { _ in }
    var options = RecordingOptions()
    options.systemAudio = false
    try await writer.prepare(url: url, size: CGSize(width: 64, height: 48), options: options)
    let time = CMClockGetTime(CMClockGetHostTimeClock()).seconds - 1
    let first = try video(time: time)
    let later = try video(time: time + 0.5)
    let outOfOrder = try video(time: time + 0.2)
    writer.queue.sync {
      writer.consumeVideo(first)
      writer.consumeVideo(later)
      writer.consumeVideo(outOfOrder)
    }
    let stream = SCStream(
      filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
    let recorder = ScreenRecorder(media: media, stream: stream, writer: writer, activeURL: url) {
      _ in
    }
    await #expect(throws: CaptureError.writerFailed) { try await recorder.stop() }
    #expect(!(await writer.hasCommittedMedia))
    #expect(recorder.segments.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
  @Test @MainActor func pauseSegmentsTrimAndMixToSingleAudioTrack() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let first = try await segment(media, origin: 100, system: true, microphone: true)
    let second = try await segment(media, origin: 120, system: true, microphone: true)
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    let exporter = RecordingExporter()
    let composition = try await exporter.composition(segments: [first, second])
    let duration = try await composition.load(.duration).seconds
    #expect(abs(duration - 2) < 0.15)
    try await exporter.export(
      segments: [first, second], trim: RecordingTrim(start: 0.25, end: 1.75, duration: duration),
      to: output)
    let asset = AVURLAsset(url: output)
    #expect(abs(try await asset.load(.duration).seconds - 1.5) < 0.1)
    let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    #expect(
      CMFormatDescriptionGetMediaSubType(
        try #require(try await audio.load(.formatDescriptions).first)) == kAudioFormatMPEG4AAC)
    let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let formats = try await video.load(.formatDescriptions)
    #expect(
      CMFormatDescriptionGetMediaSubType(try #require(formats.first)) == kCMVideoCodecType_H264)
  }
  @Test @MainActor func cancelledExportPreservesOriginalAndExistingDestination() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let source = try await segment(media, origin: 100, system: true, microphone: false)
    let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: destinationDirectory) }
    let output = destinationDirectory.appendingPathComponent("output.mp4")
    let sentinel = Data("existing destination".utf8)
    try sentinel.write(to: output)
    let exporter = RecordingExporter()
    let task = Task { try await exporter.export(segments: [source], trim: nil, to: output) }
    await Task.yield()
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(try Data(contentsOf: output) == sentinel)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path) == [
        "output.mp4"
      ])
  }
  @Test @MainActor func exportInsideMediaDirectoryCannotOverwriteSourceAndCanRetry() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let source = try await segment(media, origin: 100, system: false, microphone: false)
    let sentinel = Data("existing destination".utf8)
    let forbidden = media.directory.appendingPathComponent("output.mp4")
    try sentinel.write(to: forbidden)
    let exporter = RecordingExporter()
    await #expect(throws: CaptureError.invalidExportDestination) {
      try await exporter.export(segments: [source], trim: nil, to: forbidden)
    }
    #expect(try Data(contentsOf: forbidden) == sentinel)
    #expect(FileManager.default.fileExists(atPath: source.path))
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    try await exporter.export(segments: [source], trim: nil, to: output)
    try await media.discard()
    #expect(FileManager.default.fileExists(atPath: output.path))
  }
  @Test @MainActor func finalCommitRunsOffMainThreadAndReplacesExistingDestination() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let source = try await segment(media, origin: 100, system: false, microphone: false)
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    try Data("old movie".utf8).write(to: output)
    let onMain = OSAllocatedUnfairLock(initialState: false)
    let exporter = RecordingExporter(commit: { staging, destination in
      onMain.withLock { $0 = Thread.isMainThread }
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
    })
    try await exporter.export(segments: [source], trim: nil, to: output)
    #expect(!onMain.withLock { $0 })
    #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).count == 1)
    #expect(FileManager.default.fileExists(atPath: source.path))
  }
  @Test @MainActor func failedSaveAllowsRetryAndLeavesSource() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let source = try await segment(media, origin: 100, system: false, microphone: false)
    let exporter = RecordingExporter()
    await #expect(throws: (any Error).self) {
      try await exporter.export(
        segments: [source], trim: nil,
        to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
          .appendingPathComponent("output.mp4"))
    }
    #expect(FileManager.default.fileExists(atPath: source.path))
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    try await exporter.export(segments: [source], trim: nil, to: output)
    #expect(FileManager.default.fileExists(atPath: output.path))
  }
  @Test(arguments: [(false, false), (true, false), (false, true)]) @MainActor
  func audioOptionsProduceExpectedTracks(options: (Bool, Bool)) async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let url = try await segment(media, origin: 100, system: options.0, microphone: options.1)
    let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
    #expect(tracks.count == (options.0 || options.1 ? 1 : 0))
  }
}
