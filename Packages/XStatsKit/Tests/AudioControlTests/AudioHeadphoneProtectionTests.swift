// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CoreAudio
import Testing
@testable import AudioControl

private final class HeadphoneProtectionHardware: @unchecked Sendable {
  private let lock = NSLock()
  private var current = AudioHardwareSnapshot.empty
  private var limited: [UInt32] = []
  private var applicationsRead = false

  var requests: [UInt32] { lock.withLock { limited } }
  var enumeratedApplications: Bool { lock.withLock { applicationsRead } }
  func update(_ snapshot: AudioHardwareSnapshot) { lock.withLock { current = snapshot } }
  func client() -> AudioHardwareClient {
    AudioHardwareClient(
      selectDevice: { _, _, _ in .unsupported },
      readSnapshot: { applications in
        self.lock.withLock {
          self.applicationsRead = self.applicationsRead || applications
          return self.current
        }
      },
      limitOutputVolume: { device in
        self.lock.withLock { self.limited.append(device.id) }
        return nil
      })
  }
}

struct AudioHeadphoneProtectionTests {
  private let headphones = AudioDeviceInfo(
    id: 987_654, uid: "test.headphones", name: "Headphones", hasOutput: true,
    outputKind: .headphones)

  private func speaker(
    level: Double? = 0.8, muted: Bool = false, writable: Bool = true,
    id: UInt32 = 987_655, uid: String = "test.speaker"
  ) -> AudioDeviceInfo {
    AudioDeviceInfo(
      id: id, uid: uid, name: "Speaker", hasOutput: true, outputVolume: level,
      outputMuted: muted, canSetOutputVolume: writable, outputKind: .speaker, isBuiltIn: true)
  }

  private func snapshot(_ output: AudioDeviceInfo, others: [AudioDeviceInfo] = [])
    -> AudioHardwareSnapshot
  {
    AudioHardwareSnapshot(
      devices: [output] + others, outputID: output.id, inputID: nil, applications: [])
  }

  @Test func defaultSelectionRequiresRecognizedHeadphonesOrBuiltInSpeakers() {
    #expect(headphones.isDefaultCycleOutput)
    #expect(speaker().isDefaultCycleOutput)
    for kind: AudioOutputKind in [.speaker, .bluetooth, .usb, .display, .unknown] {
      #expect(
        !AudioDeviceInfo(
          id: 3, uid: "test.external", name: "External", hasOutput: true, outputKind: kind
        ).isDefaultCycleOutput)
    }
    #expect(
      AudioHAL.outputKind(
        transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil, terminalTypes: [],
        bluetoothHeadphones: true) == .headphones)
    #expect(
      AudioHAL.outputKind(
        transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil, terminalTypes: [],
        bluetoothHeadphones: false) == .bluetooth)
  }

  @Test func disconnectAcrossAnEmptyRouteLowersSpeakerOnlyOnceAndRetainsMute() {
    var state = AudioHeadphoneDisconnectState()
    #expect(state.outputToLimit(in: snapshot(headphones)) == nil)
    #expect(state.outputToLimit(in: .empty) == nil)
    let mutedSpeaker = speaker(muted: true)
    #expect(state.outputToLimit(in: snapshot(mutedSpeaker)) == mutedSpeaker)
    #expect(state.outputToLimit(in: snapshot(mutedSpeaker)) == nil)
    #expect(state.outputToLimit(in: snapshot(headphones)) == nil)
  }

  @Test func unpluggingAWiredJackCanKeepItsDeviceIdentity() {
    var state = AudioHeadphoneDisconnectState()
    #expect(state.outputToLimit(in: snapshot(headphones)) == nil)
    let builtIn = speaker(id: headphones.id, uid: headphones.uid)
    #expect(state.outputToLimit(in: snapshot(builtIn)) == builtIn)
  }

  @Test func manualSwitchWhileHeadphonesRemainConnectedDoesNotLowerVolume() {
    var state = AudioHeadphoneDisconnectState()
    let start = ContinuousClock.now
    #expect(state.outputToLimit(in: snapshot(headphones), now: start) == nil)
    #expect(
      state.outputToLimit(in: snapshot(speaker(), others: [headphones]), now: start) == nil)
    #expect(state.outputToLimit(in: snapshot(speaker()), now: start + .seconds(1)) == nil)
  }

  @Test func outputNotificationBeforeDeviceRemovalStillProtectsTheFallbackSpeaker() {
    var state = AudioHeadphoneDisconnectState()
    let start = ContinuousClock.now
    #expect(state.outputToLimit(in: snapshot(headphones), now: start) == nil)
    #expect(
      state.outputToLimit(in: snapshot(speaker(), others: [headphones]), now: start) == nil)
    let fallback = speaker()
    #expect(
      state.outputToLimit(in: snapshot(fallback), now: start + .milliseconds(20)) == fallback)
    #expect(
      state.outputToLimit(in: snapshot(fallback), now: start + .milliseconds(30)) == nil)
  }

  @Test(arguments: [Double?.none, .some(0), .some(0.1), .some(0.2), .some(.nan)])
  func quietOrUnknownSpeakerVolumeIsNeverRaised(level: Double?) {
    var state = AudioHeadphoneDisconnectState()
    #expect(state.outputToLimit(in: snapshot(headphones)) == nil)
    #expect(state.outputToLimit(in: snapshot(speaker(level: level))) == nil)
  }

  @Test func initialSpeakerAndUnsupportedControlsAreNotWritten() {
    var state = AudioHeadphoneDisconnectState()
    #expect(state.outputToLimit(in: snapshot(speaker())) == nil)
    #expect(state.outputToLimit(in: snapshot(headphones)) == nil)
    #expect(state.outputToLimit(in: snapshot(speaker(writable: false))) == nil)
  }

  @Test func eventProtectionStopsAndRestartsWithoutRetroactiveWritesOrApplicationReads()
    async
  {
    let fixture = HeadphoneProtectionHardware()
    fixture.update(snapshot(headphones))
    let hardware = fixture.client()
    hardware.setHeadphoneDisconnectProtection(true)
    _ = await hardware.snapshot(includeApplications: false)
    #expect(await hardware.headphoneListenerCount() > 0)
    fixture.update(snapshot(speaker()))
    _ = await hardware.snapshot(includeApplications: false)
    _ = await hardware.snapshot(includeApplications: false)
    #expect(fixture.requests == [987_655])
    hardware.setHeadphoneDisconnectProtection(false)
    #expect(await hardware.headphoneListenerCount() == 0)
    fixture.update(snapshot(headphones))
    _ = await hardware.snapshot(includeApplications: false)
    fixture.update(snapshot(speaker()))
    hardware.setHeadphoneDisconnectProtection(true)
    _ = await hardware.snapshot(includeApplications: false)
    #expect(fixture.requests == [987_655])
    #expect(!fixture.enumeratedApplications)
    hardware.setHeadphoneDisconnectProtection(false)
    #expect(await hardware.headphoneListenerCount() == 0)
  }
}
