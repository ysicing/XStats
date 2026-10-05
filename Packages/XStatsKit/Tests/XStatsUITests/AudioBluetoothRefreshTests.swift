// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Foundation
import Testing
@testable import AudioControl
@testable import XStatsUI

private final class BluetoothCatalogFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var denied = true
    private var reads = 0
    let device = BluetoothAudioDevice(address: "00:11:22:33:44:55", name: "Headphones", hasInput: true, hasOutput: true)
    func allow() { lock.withLock { denied = false } }
    var readCount: Int { lock.withLock { reads } }
    func read() throws -> [BluetoothAudioDevice] {
        let isDenied = lock.withLock { reads += 1; return denied }
        if isDenied { throw AudioControlError.bluetoothPermissionRequired }
        return [device]
    }
}

@MainActor
struct AudioBluetoothRefreshTests {
    @Test func activationRefreshesADeniedCatalogOnceWhileTheControlsRemainVisible() async throws {
        let suite = "XStats.AudioBluetoothRefreshTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = BluetoothCatalogFixture()
        let bluetooth = BluetoothAudioClient(readPaired: { try catalog.read() }, connect: { _ in }, devices: { [] })
        let notifications = NotificationCenter()
        let controller = AudioController(defaults: defaults, bluetooth: bluetooth, activationNotifications: notifications)
        defer { controller.stop() }
        controller.setDemand(enabled: true, visible: true, menuVisible: false)
        try await waitUntil { controller.error == .bluetoothPermissionRequired }
        #expect(catalog.readCount == 1)
        catalog.allow()
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { controller.bluetoothDevices == [catalog.device] }
        #expect(controller.error == nil)
        #expect(catalog.readCount == 2)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(catalog.readCount == 2, "成功读取后不因每次激活重复读取目录")
    }

    @Test func closingTheControlsStopsAuthorizationRefreshes() async throws {
        let suite = "XStats.AudioBluetoothRefreshTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = BluetoothCatalogFixture()
        let bluetooth = BluetoothAudioClient(readPaired: { try catalog.read() }, connect: { _ in }, devices: { [] })
        let notifications = NotificationCenter()
        let controller = AudioController(defaults: defaults, bluetooth: bluetooth, activationNotifications: notifications)
        defer { controller.stop() }
        controller.setDemand(enabled: true, visible: true, menuVisible: false)
        try await waitUntil { controller.error == .bluetoothPermissionRequired }
        controller.setDemand(enabled: true, visible: false, menuVisible: false)
        catalog.allow()
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(catalog.readCount == 1)
        #expect(controller.bluetoothDevices.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "蓝牙读取结果应在时限内发布")
    }
}
