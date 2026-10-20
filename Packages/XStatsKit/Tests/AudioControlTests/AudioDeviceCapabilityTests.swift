// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import CoreAudio
@testable import AudioControl

struct AudioDeviceCapabilityTests {
  @Test func outputIconsPreferEndpointInformationAndKeepUnknownTransportsGeneric() {
    #expect(
      AudioHAL.outputKind(
        transport: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6864_706E, terminalTypes: [])
        == .headphones)
    #expect(
      AudioHAL.outputKind(
        transport: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6973_706B,
        terminalTypes: [kAudioStreamTerminalTypeHeadphones]) == .speaker)
    #expect(
      AudioHAL.outputKind(
        transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil,
        terminalTypes: [kAudioStreamTerminalTypeHeadphones]) == .headphones)
    #expect(
      AudioHAL.outputKind(
        transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil,
        terminalTypes: [kAudioStreamTerminalTypeSpeaker]) == .speaker)
    #expect(
      AudioHAL.outputKind(
        transport: kAudioDeviceTransportTypeBluetoothLE, dataSource: nil, terminalTypes: [])
        == .bluetooth)
    #expect(
      AudioHAL.outputKind(
        transport: kAudioDeviceTransportTypeUSB, dataSource: nil, terminalTypes: []) == .usb)
    #expect(
      AudioHAL.outputKind(
        transport: kAudioDeviceTransportTypeHDMI, dataSource: nil, terminalTypes: []) == .display)
    #expect(
      AudioHAL.outputKind(
        transport: kAudioDeviceTransportTypeDisplayPort, dataSource: nil, terminalTypes: [])
        == .display)
    #expect(
      AudioHAL.outputKind(
        transport: kAudioDeviceTransportTypeBuiltIn, dataSource: nil, terminalTypes: []) == .speaker
    )
    #expect(AudioHAL.outputKind(transport: nil, dataSource: 123, terminalTypes: []) == .unknown)
  }

  @Test func unsupportedDefaultsNeverReachTheNativeSelectionDriver() async {
    let client = AudioHardwareClient(selectDevice: { _, _, _ in
      Issue.record("An ineligible endpoint must not be offered to the native default-device writer")
      return nil
    })
    let endpoint = AudioDeviceInfo(
      id: 1, uid: "test.virtual", name: "Virtual", hasOutput: true, canBeDefaultOutput: false)
    await #expect(throws: AudioControlError.unsupported) {
      try await client.select(endpoint, direction: .output)
    }
  }

  @Test func cancelledSystemMuteDoesNotReachAHALWrite() async {
    let client = AudioHardwareClient()
    let endpoint = AudioDeviceInfo(
      id: 0, uid: "test.invalid", name: "Test", hasOutput: true, outputMuted: false,
      canSetOutputMute: true)
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await client.setMuted(true, device: endpoint, direction: .output)
    }
    await #expect(throws: CancellationError.self) { try await operation.value }
  }
  @Test func outputStreamsDoNotImplySystemDefaultEligibility() {
    let endpoint = AudioDeviceInfo(
      id: 1, uid: "test.virtual", name: "Virtual", hasInput: true, hasOutput: true,
      canBeDefaultInput: true, canBeDefaultOutput: false)
    #expect(endpoint.hasOutput)
    #expect(endpoint.canBeDefault(.input))
    #expect(!endpoint.canBeDefault(.output))
    // 独立输出仍能使用这个端点，系统选择器只过滤默认设备能力。
    #expect([endpoint].filter(\.hasOutput).count == 1)
    #expect([endpoint].filter { $0.canBeDefault(.output) }.isEmpty)
  }

  @Test func defaultEligibilityAlsoRequiresStreamsInThatDirection() {
    let output = AudioDeviceInfo(
      id: 1, uid: "test", name: "Output", hasOutput: true, canBeDefaultInput: true,
      canBeDefaultOutput: true)
    #expect(!output.canBeDefault(.input))
    #expect(output.canBeDefault(.output))
  }
}
