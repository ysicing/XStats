// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import AudioControl

private final class BluetoothReadinessFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let ready: AudioDeviceInfo
    init(_ ready: AudioDeviceInfo) { self.ready = ready }
    func devices() -> [AudioDeviceInfo] { lock.withLock { reads += 1; return reads >= 3 ? [ready] : [] } }
}

struct BluetoothAudioTests {
    @Test func cancellationDuringCatalogReadDoesNotStartANativeConnection() async throws {
        let paired = BluetoothAudioDevice(address: "AA-BB-CC-DD-EE-FF", name: "Headphones", hasInput: true, hasOutput: true)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let client = BluetoothAudioClient(readPaired: {
            signal.yield(()); signal.finish()
            _ = release.wait(timeout: .now() + 60) // 取消后才放行；短超时会在高负载 CI 上抢在取消前返回。
            return [paired]
        }, connect: { _ in Issue.record("Cancellation must prevent starting the native connection") }, devices: { [] })
        let task = Task { try await client.connect(paired, direction: .output) }
        for await _ in started { break }
        task.cancel(); release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func anAlreadyCancelledSelectionDoesNotReachTheHALWrite() async throws {
        let hardware = AudioHardwareClient()
        let device = AudioDeviceInfo(id: 0, uid: "test.invalid", name: "Test", hasOutput: true)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await hardware.select(device, direction: .output)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func reportsDeniedBluetoothAccessInsteadOfAnEmptyCatalog() async throws {
        let client = BluetoothAudioClient(readPaired: { throw AudioControlError.bluetoothPermissionRequired }, connect: { _ in }, devices: { [] })
        await #expect(throws: AudioControlError.bluetoothPermissionRequired) { try await client.pairedDevices() }
    }
    @Test func waitsForAudioReadinessAfterConnecting() async throws {
        let paired = BluetoothAudioDevice(address: "AA-BB-CC-DD-EE-FF", name: "Headphones", hasInput: true, hasOutput: true)
        let ready = AudioDeviceInfo(id: 3, uid: "output", name: "Headphones", hasOutput: true, bluetoothAddress: paired.address)
        let fixture = BluetoothReadinessFixture(ready)
        let client = BluetoothAudioClient(readPaired: { [paired] }, connect: { _ in }, devices: { fixture.devices() },
                                          readinessTimeout: .seconds(60), pollInterval: .milliseconds(5)) // 截止时间按墙钟计算，CI 高负载下默认 8 秒不够。
        #expect(try await client.connect(paired, direction: .output) == ready)
    }

    @Test func preservesTheConnectionErrorInsteadOfWaitingForAudio() async throws {
        let paired = BluetoothAudioDevice(address: "AA-BB-CC-DD-EE-FF", name: "Headphones", hasInput: true, hasOutput: true)
        let client = BluetoothAudioClient(readPaired: { [paired] }, connect: { _ in throw AudioControlError.bluetoothConnectionFailed }, devices: { [] })
        await #expect(throws: AudioControlError.bluetoothConnectionFailed) { try await client.connect(paired, direction: .output) }
    }

    @Test func aLateNativeConnectionResultIsRejectedAfterCancellation() async throws {
        let paired = BluetoothAudioDevice(address: "AA-BB-CC-DD-EE-FF", name: "Headphones", hasInput: true, hasOutput: true)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let client = BluetoothAudioClient(readPaired: { [paired] }, connect: { _ in
            signal.yield(()); signal.finish()
            _ = release.wait(timeout: .now() + 60) // 取消后才放行；短超时会在高负载 CI 上抢在取消前返回。
        }, devices: { [] })
        let task = Task { try await client.connect(paired, direction: .output) }
        for await _ in started { break }
        task.cancel(); release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func matchesAddressAndDirectionRatherThanTheDeviceName() async throws {
        let paired = BluetoothAudioDevice(address: "AA-BB-CC-DD-EE-FF", name: "Headphones", hasInput: true, hasOutput: true)
        let wrong = AudioDeviceInfo(id: 1, uid: "other", name: "Headphones", hasOutput: true, bluetoothAddress: "11:22:33:44:55:66")
        let input = AudioDeviceInfo(id: 2, uid: "input", name: "Headphones", hasInput: true, bluetoothAddress: "aa:bb:cc:dd:ee:ff")
        let output = AudioDeviceInfo(id: 3, uid: "output", name: "Headphones", hasOutput: true, bluetoothAddress: "aa:bb:cc:dd:ee:ff")
        let client = BluetoothAudioClient(readPaired: { [paired] }, connect: { _ in }, devices: { [wrong, input, output] })
        #expect(try await client.connect(paired, direction: .output).id == 3)
        #expect(try await client.connect(paired, direction: .input).id == 2)
    }

    @Test func aConnectedBasebandWithoutAnAudioDeviceTimesOut() async throws {
        let paired = BluetoothAudioDevice(address: "AA-BB-CC-DD-EE-FF", name: "Headphones", hasInput: false, hasOutput: true)
        let client = BluetoothAudioClient(readPaired: { [paired] }, connect: { _ in }, devices: { [] }, readinessTimeout: .milliseconds(15), pollInterval: .milliseconds(5))
        await #expect(throws: AudioControlError.bluetoothAudioUnavailable) { try await client.connect(paired, direction: .output) }
    }

    @Test func aForgottenDeviceCannotBeConnectedFromAnOldCatalog() async throws {
        let paired = BluetoothAudioDevice(address: "AA-BB-CC-DD-EE-FF", name: "Headphones", hasInput: true, hasOutput: true)
        let client = BluetoothAudioClient(readPaired: { [] }, connect: { _ in Issue.record("An unpaired device must not start connecting") }, devices: { [] })
        await #expect(throws: AudioControlError.routeChanged) { try await client.connect(paired, direction: .output) }
    }

    @Test func cancellationStopsReadinessWaitingWithoutSelectingAnyRoute() async throws {
        let paired = BluetoothAudioDevice(address: "AA-BB-CC-DD-EE-FF", name: "Headphones", hasInput: true, hasOutput: true)
        let client = BluetoothAudioClient(readPaired: { [paired] }, connect: { _ in }, devices: { [] }, pollInterval: .milliseconds(5))
        let task = Task { try await client.connect(paired, direction: .output) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func extractsOnlyAValidAddressFromBluetoothUIDs() {
        #expect(BluetoothAudioDevice.address(in: "AA-BB-CC-DD-EE-FF:output") == "aabbccddeeff")
        #expect(BluetoothAudioDevice.address(in: "aa:bb:cc:dd:ee:ff:input") == "aabbccddeeff")
        #expect(BluetoothAudioDevice.address(in: "BuiltInSpeakerDevice") == nil)
        #expect(BluetoothAudioDevice.address(in: "invalid-AA-BB-CC-DD-EE-FF") == nil)
    }
}
