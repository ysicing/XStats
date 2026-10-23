// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreAudio
import Foundation
import Testing
@testable import AudioControl

struct AudioMixerFormatTests {
  private func format(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector
  ) throws -> AudioStreamBasicDescription {
    var property = AudioHAL.address(selector)
    var value = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try #require(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr)
    return value
  }

  private func mixerDeviceUIDs() -> Set<String> {
    Set(
      (AudioHAL.ids(AudioHAL.system, kAudioHardwarePropertyDevices) ?? [])
        .compactMap { AudioHAL.string($0, kAudioDevicePropertyDeviceUID) }
        .filter { $0.hasPrefix("XStats.Audio.") })
  }

  @Test(
    .serialized,
    .enabled(
      if: ProcessInfo.processInfo.environment["XSTATS_AUDIO_TEST_OUTPUT_UID"] != nil,
      "Requires an explicitly selected local output device; does not change the default route."),
    arguments: [false, true])
  func startsWithSelectedAndSystemOutputRatesAndReleasesItsResources(usesSystemOutput: Bool)
    async throws
  {
    guard #available(macOS 14.4, *) else { return }
    let selectedUID = try #require(
      ProcessInfo.processInfo.environment["XSTATS_AUDIO_TEST_OUTPUT_UID"])
    let defaultOutput = try #require(AudioHAL.defaultDevice(.output))
    let defaultUID = try #require(AudioHAL.string(defaultOutput, kAudioDevicePropertyDeviceUID))
    let outputUID = usesSystemOutput ? defaultUID : selectedUID
    let output = try #require(
      AudioHAL.ids(AudioHAL.system, kAudioHardwarePropertyDevices)?.first {
        AudioHAL.string($0, kAudioDevicePropertyDeviceUID) == outputUID
      })
    if !usesSystemOutput {
      let description = CATapDescription(stereoMixdownOfProcesses: [])
      description.isPrivate = true
      description.muteBehavior = .unmuted
      var tap: AudioObjectID = 0
      try #require(AudioHardwareCreateProcessTap(description, &tap) == noErr)
      defer { #expect(AudioHardwareDestroyProcessTap(tap) == noErr) }
      let nativeFormat = try format(tap, selector: kAudioTapPropertyFormat)
      let outputStream = try #require(
        AudioHAL.ids(
          output, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)?.first)
      let outputFormat = try format(outputStream, selector: kAudioStreamPropertyVirtualFormat)
      try #require(nativeFormat.mSampleRate != outputFormat.mSampleRate)
    }
    let initialSignature = try #require(AudioHAL.streamSignature(outputUID))
    let initialDevices = mixerDeviceUIDs()
    let target = AudioMixTarget(
      id: "format-regression", processObjectIDs: [],
      volume: try #require(AudioAppVolume(level: 0.5)))
    for _ in 0..<2 {
      let pipeline = CoreAudioMixPipeline(
        target: target, outputUID: outputUID,
        sourceUID: defaultUID)
      defer {
        do { try pipeline.stop() } catch { Issue.record(error) }
      }
      try pipeline.start(shouldContinue: { true })
      #expect(pipeline.isOutputPresent)
      let ownedDevices = mixerDeviceUIDs().subtracting(initialDevices)
      #expect(ownedDevices.count == 1)
      try pipeline.stop()
      for _ in 0..<50 {
        if mixerDeviceUIDs().isDisjoint(with: ownedDevices) { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(mixerDeviceUIDs().isDisjoint(with: ownedDevices))
    }
    #expect(AudioHAL.defaultDevice(.output) == defaultOutput)
    #expect(AudioHAL.streamSignature(outputUID) == initialSignature)
    #expect(AudioHAL.uint(output, kAudioDevicePropertyDeviceIsAlive) == 1)
  }
}
