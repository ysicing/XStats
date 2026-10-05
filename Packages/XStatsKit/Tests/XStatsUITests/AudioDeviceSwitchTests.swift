// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import AudioControl
@testable import XStatsUI

private final class PendingDefaultSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    let release = DispatchSemaphore(value: 0)
    let signal: AsyncStream<Void>.Continuation
    init(signal: AsyncStream<Void>.Continuation) { self.signal = signal }
    func select(_ cancellation: AudioOperationCancellation) -> AudioControlError? {
        signal.yield(()); signal.finish()
        _ = release.wait(timeout: .now() + 60)
        if cancellation.isCancelled { return .routeChanged }
        lock.withLock { writes += 1 }
        return nil
    }
    var writeCount: Int { lock.withLock { writes } }
}

@MainActor
struct AudioDeviceSwitchTests {
    @Test(arguments: [AudioDirection.input, .output])
    func disablingCancelsAnOrdinaryDeviceSwitchBeforeItsQueuedWrite(direction: AudioDirection) async throws {
        let suite = "XStats.AudioDeviceSwitchTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let gate = PendingDefaultSelection(signal: signal)
        defer { gate.release.signal() }
        let hardware = AudioHardwareClient(selectDevice: { _, _, cancellation in gate.select(cancellation) })
        let controller = AudioController(defaults: defaults, hardware: hardware)
        defer { controller.stop() }
        let a = AudioDeviceInfo(id: 1, uid: "test.a", name: "A", hasInput: true, hasOutput: true)
        let b = AudioDeviceInfo(id: 2, uid: "test.b", name: "B", hasInput: true, hasOutput: true)
        controller.showPreview(AudioHardwareSnapshot(devices: [a,b], outputID: 1, inputID: 1, applications: []), volumes: [:], outputs: [:])
        // 不展示设备页或菜单栏，避免真实蓝牙目录读取；选择和写入使用替身。
        controller.setDemand(enabled: true, visible: false, menuVisible: false)
        controller.selectDevice(b.id, direction: direction)
        for await _ in started { break }
        controller.setDemand(enabled: false, visible: false, menuVisible: false)
        gate.release.signal()
        _ = await hardware.snapshot(includeApplications: false) // 串行屏障，确保队列中的选择已经返回。
        #expect(gate.writeCount == 0)
        #expect(!controller.isWorking)
        #expect(controller.error == nil)
    }
}
