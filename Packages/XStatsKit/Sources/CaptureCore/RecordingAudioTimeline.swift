// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation

/// Confined to RecordingWriter.queue. AAC consumes contiguous PCM frames;
/// timestamps alone cannot preserve gaps or correct the source clock's drift.
final class RecordingAudioTimeline {
  private var inputFormat: AVAudioFormat?
  private var format: AVAudioFormat?
  private var converter: AVAudioConverter?
  private var anchor: CMTime?
  private var nextFrame: Int64 = 0
  private(set) var clockFrames: Int64 = 0
  private(set) var silenceFrames: Int64 = 0
  private(set) var overlapFrames: Int64 = 0
  private static let maximumBytes = 4 * 1024 * 1024

  func normalize(_ sample: CMSampleBuffer) throws -> [CMSampleBuffer] {
    guard let description = CMSampleBufferGetFormatDescription(sample),
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
      asbd.pointee.mFormatID == kAudioFormatLinearPCM
    else { throw CaptureError.writerFailed }
    let rate = asbd.pointee.mSampleRate
    let channels = Int(asbd.pointee.mChannelsPerFrame)
    let frames = CMSampleBufferGetNumSamples(sample)
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
    guard rate.isFinite, (8000...192000).contains(rate), rate == rate.rounded(),
      (1...8).contains(channels),
      frames > 0, frames <= Self.maximumBytes / (channels * 4), timestamp.isNumeric
    else { throw CaptureError.writerFailed }
    let sourceFrameBytes =
      Int(asbd.pointee.mBytesPerFrame)
      * (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? channels : 1)
    guard sourceFrameBytes > 0, sourceFrameBytes <= Self.maximumBytes,
      frames <= Self.maximumBytes / sourceFrameBytes
    else { throw CaptureError.writerFailed }
    let source = AVAudioFormat(cmAudioFormatDescription: description)
    if inputFormat == nil {
      guard
        let output = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: rate,
          channels: AVAudioChannelCount(channels), interleaved: true),
        let conversion = AVAudioConverter(from: source, to: output)
      else { throw CaptureError.writerFailed }
      inputFormat = source
      format = output
      converter = conversion
      anchor = timestamp
    }
    guard source == inputFormat, let format, let converter, let anchor,
      let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)),
      let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { throw CaptureError.writerFailed }
    input.frameLength = AVAudioFrameCount(frames)
    guard
      CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr
    else { throw CaptureError.writerFailed }
    do { try converter.convert(to: output, from: input) } catch { throw CaptureError.writerFailed }
    guard output.frameLength == frames, let data = output.audioBufferList.pointee.mBuffers.mData
    else { throw CaptureError.writerFailed }
    let position = (timestamp - anchor).seconds * rate
    guard position.isFinite, position >= 0, position < Double(Int64.max / 2) else {
      throw CaptureError.writerFailed
    }
    let desiredFrame = Int64(position.rounded())
    let delta = desiredFrame - nextFrame
    guard abs(delta) <= Int64(rate),
      frames + max(0, Int(delta)) <= Self.maximumBytes / (channels * 4)
    else { throw CaptureError.writerFailed }
    let values = data.assumingMemoryBound(to: Float.self)
    var result: [CMSampleBuffer] = []
    if delta != 0, frames >= 256, abs(delta) <= Int64(max(1, frames / 1000)) {
      // Spread a sub-millisecond clock correction over this buffer,
      // rather than inserting zero samples into an otherwise smooth wave.
      let count = frames + Int(delta)
      var corrected = [Float](repeating: 0, count: count * channels)
      for frame in 0..<count {
        let position = Double(frame) * Double(frames - 1) / Double(count - 1)
        let lower = Int(position)
        let upper = min(lower + 1, frames - 1)
        let fraction = Float(position - Double(lower))
        for channel in 0..<channels {
          let a = values[lower * channels + channel]
          let b = values[upper * channels + channel]
          corrected[frame * channels + channel] = a + (b - a) * fraction
        }
      }
      result.append(try makeSample(corrected, frames: count, format: format, anchor: anchor))
      clockFrames += delta
      return result
    }
    if delta > 0 {
      let count = Int(delta)
      result.append(
        try makeSample(
          [Float](repeating: 0, count: count * channels), frames: count, format: format,
          anchor: anchor))
      silenceFrames += delta
    }
    let skipped = min(frames, max(0, -Int(delta)))
    overlapFrames += Int64(skipped)
    guard skipped < frames else { return result }
    let count = frames - skipped
    let retained = Array(
      UnsafeBufferPointer(start: values + skipped * channels, count: count * channels))
    result.append(try makeSample(retained, frames: count, format: format, anchor: anchor))
    return result
  }

  private func makeSample(_ values: [Float], frames: Int, format: AVAudioFormat, anchor: CMTime)
    throws -> CMSampleBuffer
  {
    var block: CMBlockBuffer?
    let bytes = values.count * MemoryLayout<Float>.size
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: bytes,
        flags: 0, blockBufferOut: &block) == noErr, let block
    else { throw CaptureError.writerFailed }
    let status = values.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
    }
    guard status == noErr else { throw CaptureError.writerFailed }
    let scale = Int32(format.sampleRate.rounded())
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: scale),
      presentationTimeStamp: anchor + CMTime(value: nextFrame, timescale: scale),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: format.formatDescription, sampleCount: frames, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
        sampleBufferOut: &sample) == noErr,
      let sample
    else { throw CaptureError.writerFailed }
    nextFrame += Int64(frames)
    return sample
  }
}
