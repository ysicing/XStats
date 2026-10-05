// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import IOBluetooth
import CoreBluetooth

/// 已配对的音频能力来自缓存的设备类别与 SDP，不发起附近设备扫描或远程服务查询。
public struct BluetoothAudioDevice: Sendable, Equatable, Identifiable {
    public let address: String
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool
    public var id: String { Self.address(in: address) ?? address.lowercased() }

    public init(address: String, name: String, hasInput: Bool, hasOutput: Bool) {
        self.address = address; self.name = name; self.hasInput = hasInput; self.hasOutput = hasOutput
    }

    /// Bluetooth HAL UID 通常以设备地址开头；不用名称匹配，避免同名耳机切错设备。
    static func address(in uid: String) -> String? {
        let hexadecimal = Set("0123456789abcdef")
        let text = uid.lowercased()
        let prefix = String(text.prefix(17))
        let components = prefix.split(whereSeparator: { $0 == "-" || $0 == ":" })
        if components.count == 6, components.allSatisfy({ $0.count == 2 && $0.allSatisfy(hexadecimal.contains) }),
           text.count == 17 || [":", "/"].contains(String(text.dropFirst(17).prefix(1))) {
            return components.joined()
        }
        let compact = String(text.prefix(12))
        guard compact.count == 12, compact.allSatisfy(hexadecimal.contains),
              text.count == 12 || [":", "/"].contains(String(text.dropFirst(12).prefix(1))) else { return nil }
        return compact
    }

    public func matches(_ device: AudioDeviceInfo, direction: AudioDirection) -> Bool {
        guard let address = device.bluetoothAddress, Self.address(in: address) == id else { return false }
        return direction == .output ? device.hasOutput : device.hasInput
    }
}

/// 原生对象仅在串行队列局部使用；不可变闭包和参数可安全跨线程共享。
/// 连接调用有 10 秒分页超时，之后最多等 8 秒音频就绪；没有后台重连或常驻轮询。
public final class BluetoothAudioClient: Sendable {
    private let queue = DispatchQueue(label: "work.12306.xstats.audio.bluetooth", qos: .userInitiated)
    private let readPaired: @Sendable () throws -> [BluetoothAudioDevice]
    private let connectDevice: @Sendable (String) throws -> Void
    private let readDevices: @Sendable () -> [AudioDeviceInfo]
    private let readinessTimeout: Duration
    private let pollInterval: Duration

    public convenience init() {
        self.init(readPaired: Self.pairedDevices, connect: Self.openConnection, devices: { AudioHAL.devices() })
    }

    init(readPaired: @escaping @Sendable () throws -> [BluetoothAudioDevice], connect: @escaping @Sendable (String) throws -> Void,
         devices: @escaping @Sendable () -> [AudioDeviceInfo], readinessTimeout: Duration = .seconds(8), pollInterval: Duration = .milliseconds(250)) {
        self.readPaired = readPaired; connectDevice = connect; readDevices = devices
        self.readinessTimeout = readinessTimeout; self.pollInterval = pollInterval
    }

    public func pairedDevices() async throws -> [BluetoothAudioDevice] {
        let cancellation = AudioOperationCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let devices = try await execute { [readPaired] in
                try cancellation.check()
                return try readPaired()
            }
            try Task.checkCancellation()
            return devices
        } onCancel: { cancellation.cancel() }
    }

    /// 仅发起用户选择的连接。取消后不会切换音频，也不主动断开可能已建立的系统连接。
    public func connect(_ device: BluetoothAudioDevice, direction: AudioDirection) async throws -> AudioDeviceInfo {
        let cancellation = AudioOperationCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let initial: AudioDeviceInfo? = try await execute { [self] in
                try cancellation.check()
                guard try readPaired().contains(where: { $0.id == device.id }) else { throw AudioControlError.routeChanged }
                guard direction == .output ? device.hasOutput : device.hasInput else { throw AudioControlError.unsupported }
                if let ready = readDevices().first(where: { device.matches($0, direction: direction) }) { return ready }
                try cancellation.check()
                try connectDevice(device.address)
                try cancellation.check()
                return Optional<AudioDeviceInfo>.none
            }
            try Task.checkCancellation()
            if let initial { return initial }
            let deadline = ContinuousClock.now + readinessTimeout
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if let ready = try await execute({ [readDevices] in
                    try cancellation.check()
                    return readDevices().first(where: { device.matches($0, direction: direction) })
                }) {
                    try Task.checkCancellation()
                    return ready
                }
                try await Task.sleep(for: pollInterval, tolerance: .milliseconds(20))
            }
            throw AudioControlError.bluetoothAudioUnavailable
        } onCancel: { cancellation.cancel() }
    }

    private func execute<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func pairedDevices() throws -> [BluetoothAudioDevice] {
        if CBManager.authorization == .denied || CBManager.authorization == .restricted { throw AudioControlError.bluetoothPermissionRequired }
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        if CBManager.authorization == .denied || CBManager.authorization == .restricted { throw AudioControlError.bluetoothPermissionRequired }
        return devices.prefix(256).compactMap { device in
            guard device.isPaired(), let address = device.addressString, BluetoothAudioDevice.address(in: address) != nil else { return nil }
            // 只读取系统缓存的服务记录，不执行 performSDPQuery。
            let headset = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1108)) != nil
                || device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x111E)) != nil
                || device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1131)) != nil
            let sink = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x110B)) != nil
            let audio = device.deviceClassMajor == kBluetoothDeviceClassMajorAudio
            let minor = device.deviceClassMinor
            let microphone = audio && minor == kBluetoothDeviceClassMinorAudioMicrophone
            let duplex = audio && (minor == kBluetoothDeviceClassMinorAudioHeadset || minor == kBluetoothDeviceClassMinorAudioHandsFree)
            let outputClasses = [kBluetoothDeviceClassMinorAudioUnclassified, kBluetoothDeviceClassMinorAudioHeadset,
                kBluetoothDeviceClassMinorAudioHandsFree, kBluetoothDeviceClassMinorAudioLoudspeaker,
                kBluetoothDeviceClassMinorAudioHeadphones, kBluetoothDeviceClassMinorAudioPortable,
                kBluetoothDeviceClassMinorAudioCar, kBluetoothDeviceClassMinorAudioHiFi,
                kBluetoothDeviceClassMinorAudioVideoDisplayAndLoudspeaker]
            let output = sink || headset || (audio && outputClasses.contains(Int(minor)))
            let input = headset || duplex || microphone
            guard input || output else { return nil }
            return BluetoothAudioDevice(address: address, name: device.name ?? address, hasInput: input, hasOutput: output)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func openConnection(_ address: String) throws {
        guard let host = IOBluetoothHostController.default(), host.powerState == kBluetoothHCIPowerStateON else { throw AudioControlError.bluetoothUnavailable }
        guard let device = IOBluetoothDevice(addressString: address), device.isPaired() else { throw AudioControlError.routeChanged }
        if device.isConnected() { return }
        // nil target 使用同步原生接口，必须在后台队列调用；0x3E80 × 0.625ms = 10 秒。
        let status = device.openConnection(nil, withPageTimeout: 0x3E80, authenticationRequired: false)
        if status == kIOReturnNotPermitted || status == kIOReturnNotPrivileged { throw AudioControlError.bluetoothPermissionRequired }
        guard status == kIOReturnSuccess || device.isConnected() else { throw AudioControlError.bluetoothConnectionFailed }
    }
}

/// 取消可能发生在任意线程；锁只保护标志，不跨原生连接调用或 await 持有。
final class AudioOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if isCancelled { throw CancellationError() } }
}
