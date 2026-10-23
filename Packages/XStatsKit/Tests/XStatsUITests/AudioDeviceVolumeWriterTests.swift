// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Foundation
import Testing
@testable import AudioControl
@testable import XStatsUI

private actor VolumeWriteGate {
  private var release: CheckedContinuation<Void, Never>?
  private var waiting: CheckedContinuation<Void, Never>?
  private(set) var levels: [Double] = []
  private(set) var unmutedDirections: [AudioDirection] = []
  private(set) var unmutedLevels: [Double] = []
  func write(_ request: AudioDeviceVolumeRequest) async {
    levels.append(request.level)
    if levels.count == 1 {
      await withCheckedContinuation { continuation in
        release = continuation
        waiting?.resume()
        waiting = nil
      }
    }
  }
  func started() async {
    if release != nil { return }
    await withCheckedContinuation { waiting = $0 }
  }
  func unmute(_ request: AudioDeviceVolumeRequest) {
    unmutedDirections.append(request.direction)
    unmutedLevels.append(request.level)
  }
  func resume() {
    release?.resume()
    release = nil
  }
}

@MainActor
private final class DeviceVolumeSwitchFixture {
  let gate = VolumeWriteGate()
  let controller: AudioController
  let writer: AudioDeviceVolumeWriter
  let hardware: AudioHardwareClient
  let notifications = NotificationCenter()
  let events: AsyncStream<String>
  let signal: AsyncStream<String>.Continuation
  let suite = "XStats.DeviceVolumeSwitch.\(UUID())"
  let defaults: UserDefaults

  init() throws {
    defaults = try #require(UserDefaults(suiteName: suite))
    let stream = AsyncStream<String>.makeStream()
    events = stream.stream
    signal = stream.continuation
    let gate = gate
    let signal = signal
    writer = AudioDeviceVolumeWriter(
      write: { await gate.write($0) },
      unmute: {
        await gate.unmute($0)
        signal.yield("unmute")
      },
      finished: { _, _ in signal.yield("finished") })
    let devices = [
      AudioDeviceInfo(
        id: 1, uid: "test.a", name: "A", hasInput: true, hasOutput: true,
        inputMuted: true, outputMuted: true),
      AudioDeviceInfo(id: 2, uid: "test.b", name: "B", hasInput: true, hasOutput: true),
    ]
    let snapshot = AudioHardwareSnapshot(
      devices: devices, outputID: 1, inputID: 1, applications: [])
    hardware = AudioHardwareClient(
      selectDevice: { _, _, _ in
        signal.yield("select")
        return nil
      }, readSnapshot: { _ in snapshot })
    controller = AudioController(
      defaults: defaults, hardware: hardware, volumeWriter: writer,
      bluetooth: BluetoothAudioClient(readPaired: { [] }, connect: { _ in }, devices: { [] }),
      sleepNotifications: notifications)
    controller.showPreview(snapshot, volumes: [:], outputs: [:])
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
  }

  func stop() async {
    controller.stop()
    await gate.resume()
    await writer.flush()
    signal.finish()
    defaults.removePersistentDomain(forName: suite)
  }
}

@MainActor
struct AudioDeviceVolumeWriterTests {
  private func request(_ level: Double) -> AudioDeviceVolumeRequest {
    let device = AudioDeviceInfo(
      id: 1, uid: "test", name: "Test", hasInput: true, hasOutput: true,
      inputVolume: 0.5, outputVolume: 0.5, inputMuted: false, outputMuted: false,
      canSetInputVolume: true, canSetOutputVolume: true, canSetInputMute: true,
      canSetOutputMute: true)
    return AudioDeviceVolumeRequest(level: level, device: device, direction: .output)
  }
  @Test func draggingKeepsOnlyTheNewestPendingLevelWithoutCancellingAnInFlightWrite() async {
    let gate = VolumeWriteGate()
    var completed: [Double] = []
    let writer = AudioDeviceVolumeWriter(
      write: { await gate.write($0) }, unmute: { await gate.unmute($0) },
      finished: { request, _ in completed.append(request.level) })
    writer.submit(request(0.1))
    await gate.started()
    for level in [0.2, 0.3, 0.4, 0.9] { writer.submit(request(level)) }
    await gate.resume()
    await writer.flush()
    #expect(await gate.levels == [0.1, 0.9])
    #expect(completed == [0.9])
  }
  @Test func closingTheFeatureDropsPendingWritesAndLateCompletion() async {
    let gate = VolumeWriteGate()
    var completed = 0
    let writer = AudioDeviceVolumeWriter(
      write: { await gate.write($0) }, unmute: { await gate.unmute($0) },
      finished: { _, _ in completed += 1 })
    writer.submit(request(0.1))
    await gate.started()
    writer.submit(request(0.9))
    writer.cancelPending()
    await gate.resume()
    await writer.flush()
    #expect(await gate.levels == [0.1])
    #expect(completed == 0)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [AudioDirection.input, .output])
  func cancellingAnInFlightVolumeWritePreventsItsFollowUpUnmute(direction: AudioDirection)
    async
  {
    let gate = VolumeWriteGate()
    var completed: [Double] = []
    let writer = AudioDeviceVolumeWriter(
      write: { await gate.write($0) }, unmute: { await gate.unmute($0) },
      finished: { request, _ in completed.append(request.level) })
    let device = AudioDeviceInfo(
      id: 1, uid: "test", name: "Test", hasInput: true, hasOutput: true,
      inputMuted: true, outputMuted: true)
    writer.submit(.init(level: 0.4, device: device, direction: direction))
    await gate.started()
    writer.cancelPending()
    await gate.resume()
    await writer.flush()
    #expect(await gate.levels == [0.4])
    #expect(await gate.unmutedDirections.isEmpty)
    #expect(completed.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [AudioDirection.input, .output])
  func discardingPendingWritesKeepsTheInFlightUnmute(direction: AudioDirection) async {
    let gate = VolumeWriteGate()
    var completed: [Double] = []
    let writer = AudioDeviceVolumeWriter(
      write: { await gate.write($0) }, unmute: { await gate.unmute($0) },
      finished: { request, _ in completed.append(request.level) })
    let device = AudioDeviceInfo(
      id: 1, uid: "test", name: "Test", hasInput: true, hasOutput: true,
      inputMuted: true, outputMuted: true)
    writer.submit(.init(level: 0.4, device: device, direction: direction))
    await gate.started()
    writer.submit(.init(level: 0.9, device: device, direction: direction))
    writer.discardPending()
    await gate.resume()
    await writer.flush()
    #expect(await gate.levels == [0.4])
    #expect(await gate.unmutedLevels == [0.4])
    #expect(completed.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [AudioDirection.input, .output])
  func reactivationQueuesAFreshWriteWhileTheCancelledHALWriteFinishes(direction: AudioDirection)
    async
  {
    let gate = VolumeWriteGate()
    var completed: [Double] = []
    let writer = AudioDeviceVolumeWriter(
      write: { await gate.write($0) }, unmute: { await gate.unmute($0) },
      finished: { request, error in
        #expect(error == nil)
        completed.append(request.level)
      })
    let device = AudioDeviceInfo(
      id: 1, uid: "test", name: "Test", hasInput: true, hasOutput: true,
      inputMuted: true, outputMuted: true)
    writer.submit(.init(level: 0.4, device: device, direction: direction))
    await gate.started()
    writer.cancelPending()
    writer.submit(.init(level: 0.9, device: device, direction: direction))
    await gate.resume()
    await writer.flush()
    #expect(await gate.levels == [0.4, 0.9])
    #expect(await gate.unmutedDirections == [direction])
    #expect(await gate.unmutedLevels == [0.9])
    #expect(completed == [0.9])
  }

  @Test(.timeLimit(.minutes(1)), arguments: [AudioDirection.input, .output])
  func volumeRequestsUnmuteOnlyTheirMutedDirectionAtAPositiveLevel(direction: AudioDirection)
    async
  {
    let gate = VolumeWriteGate()
    let writer = AudioDeviceVolumeWriter(
      write: { await gate.write($0) }, unmute: { await gate.unmute($0) },
      finished: { _, error in #expect(error == nil) })
    let device = AudioDeviceInfo(
      id: 1, uid: "test", name: "Test", hasInput: true, hasOutput: true,
      inputMuted: true, outputMuted: false)
    writer.submit(.init(level: 0, device: device, direction: direction))
    await gate.started()
    await gate.resume()
    await writer.flush()
    #expect(await gate.unmutedDirections.isEmpty)
    writer.submit(.init(level: 0.5, device: device, direction: direction))
    await writer.flush()
    let expected: [AudioDirection] = direction == .input ? [.input] : []
    #expect(await gate.unmutedDirections == expected)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [AudioDirection.input, .output])
  func deviceSwitchWaitsForTheInFlightVolumeWriteAndUnmute(direction: AudioDirection)
    async throws
  {
    let fixture = try DeviceVolumeSwitchFixture()
    fixture.controller.setDeviceLevel(0.4, direction: direction)
    await fixture.gate.started()
    fixture.controller.setDeviceLevel(0.9, direction: direction)
    let operation = try #require(fixture.controller.selectDevice(2, direction: direction))
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    _ = await fixture.hardware.snapshot(includeApplications: false)
    await fixture.gate.resume()
    await operation.value
    await fixture.writer.flush()
    #expect(!fixture.controller.isWorking)
    #expect(fixture.controller.switchingDevice == nil)
    await fixture.stop()
    var events: [String] = []
    for await event in fixture.events { events.append(event) }
    #expect(events == ["unmute", "select"])
    #expect(await fixture.gate.levels == [0.4])
    #expect(await fixture.gate.unmutedDirections == [direction])
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "disable", "sleep", "hide"])
  func invalidatedSwitchDoesNotRunAfterTheVolumeWriteFinishes(_ invalidation: String)
    async throws
  {
    let fixture = try DeviceVolumeSwitchFixture()
    fixture.controller.setDeviceLevel(0.4, direction: .input)
    await fixture.gate.started()
    let operation = try #require(fixture.controller.selectDevice(2, direction: .input))
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    _ = await fixture.hardware.snapshot(includeApplications: false)
    switch invalidation {
    case "disable":
      fixture.controller.setDemand(enabled: false, visible: false, menuVisible: false)
    case "sleep":
      fixture.notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
    case "hide":
      fixture.controller.setDemand(enabled: true, visible: false, menuVisible: true)
      fixture.controller.setDemand(enabled: true, visible: false, menuVisible: false)
    default:
      operation.cancel()
    }
    await fixture.gate.resume()
    await operation.value
    await fixture.writer.flush()
    let unmuted = await fixture.gate.unmutedDirections
    #expect(!fixture.controller.isWorking)
    #expect(fixture.controller.switchingDevice == nil)
    #expect(fixture.controller.error == nil)
    await fixture.stop()
    var events: [String] = []
    for await event in fixture.events { events.append(event) }
    #expect(!events.contains("select"))
    #expect(unmuted == (["disable", "sleep"].contains(invalidation) ? [] : [.input]))
  }
}
