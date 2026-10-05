// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import AudioControl
@testable import XStatsUI

private actor VolumeWriteGate {
    private var release: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var levels: [Double] = []
    func write(_ request: AudioDeviceVolumeRequest) async {
        levels.append(request.level)
        if levels.count == 1 {
            await withCheckedContinuation { continuation in
                release = continuation; waiting?.resume(); waiting = nil
            }
        }
    }
    func started() async {
        if release != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func resume() { release?.resume(); release = nil }
}
@MainActor
struct AudioDeviceVolumeWriterTests {
    private func request(_ level: Double) -> AudioDeviceVolumeRequest {
        let device = AudioDeviceInfo(id: 1, uid: "test", name: "Test", hasInput: true, hasOutput: true,
            inputVolume: 0.5, outputVolume: 0.5, inputMuted: false, outputMuted: false,
            canSetInputVolume: true, canSetOutputVolume: true, canSetInputMute: true, canSetOutputMute: true)
        return AudioDeviceVolumeRequest(level: level, device: device, direction: .output)
    }
    @Test func draggingKeepsOnlyTheNewestPendingLevelWithoutCancellingAnInFlightWrite() async {
        let gate = VolumeWriteGate()
        var completed: [Double] = []
        let writer = AudioDeviceVolumeWriter(write: { await gate.write($0) }, finished: { request, _ in completed.append(request.level) })
        writer.submit(request(0.1))
        await gate.started()
        for level in [0.2, 0.3, 0.4, 0.9] { writer.submit(request(level)) }
        await gate.resume(); await writer.flush()
        #expect(await gate.levels == [0.1, 0.9])
        #expect(completed == [0.9])
    }
    @Test func closingTheFeatureDropsPendingWritesAndLateCompletion() async {
        let gate = VolumeWriteGate()
        var completed = 0
        let writer = AudioDeviceVolumeWriter(write: { await gate.write($0) }, finished: { _, _ in completed += 1 })
        writer.submit(request(0.1)); await gate.started()
        writer.submit(request(0.9)); writer.cancelPending()
        await gate.resume(); await writer.flush()
        #expect(await gate.levels == [0.1])
        #expect(completed == 0)
    }
}
