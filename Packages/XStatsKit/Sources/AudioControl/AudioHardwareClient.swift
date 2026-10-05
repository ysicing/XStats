// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreAudio
import Foundation

/// 所有 HAL 读写、观察者和回调状态均限定在 queue；向调用方只返回 Sendable 快照。
public final class AudioHardwareClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "work.12306.xstats.audio.hardware", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var callback: (@Sendable () -> Void)?
    private var watchingApplications = false
    private var listening = false
    private var systemListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var detailListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var detailKey: [UInt32] = []
    private let selectDevice: @Sendable (AudioDeviceInfo, AudioDirection, AudioOperationCancellation) -> AudioControlError?

    public convenience init() { self.init(selectDevice: Self.selectDefaultDevice) }
    init(selectDevice: @escaping @Sendable (AudioDeviceInfo, AudioDirection, AudioOperationCancellation) -> AudioControlError?) {
        self.selectDevice = selectDevice
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil { removeListeners() }
        else { queue.sync { removeListeners() } }
    }

    public func snapshot(includeApplications: Bool) async -> AudioHardwareSnapshot {
        await execute { [self] in
            let snapshot = AudioHardwareSnapshot(devices: AudioHAL.devices(), outputID: AudioHAL.defaultDevice(.output),
                inputID: AudioHAL.defaultDevice(.input), applications: includeApplications ? AudioHAL.applications() : [])
            if listening { bindDetails(snapshot) }
            return snapshot
        }
    }

    public func watch(applications: Bool, onChange: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            callback = onChange
            guard !listening || watchingApplications != applications else { return }
            removeListeners()
            listening = true
            watchingApplications = applications
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
                addListener(AudioHAL.system, AudioHAL.address(selector), detail: false)
            }
            if applications, #available(macOS 14.4, *) {
                addListener(AudioHAL.system, AudioHAL.address(kAudioHardwarePropertyProcessObjectList), detail: false)
            }
            let snapshot = AudioHardwareSnapshot(devices: AudioHAL.devices(), outputID: AudioHAL.defaultDevice(.output),
                                                inputID: AudioHAL.defaultDevice(.input), applications: [])
            bindDetails(snapshot)
        }
    }

    public func stopWatching() {
        queue.async { [self] in removeListeners(); callback = nil }
    }

    public func setVolume(_ level: Double, device: AudioDeviceInfo, direction: AudioDirection) async throws {
        guard level.isFinite, (0...1).contains(level) else { throw AudioControlError.unsupported }
        let result: AudioControlError? = await execute {
            guard AudioHAL.defaultDevice(direction) == device.id,
                  AudioHAL.string(device.id, kAudioDevicePropertyDeviceUID) == device.uid else { return .routeChanged }
            let properties = AudioHAL.writableElements(device.id, direction: direction, selector: kAudioDevicePropertyVolumeScalar)
            guard !properties.isEmpty else { return .unsupported }
            for var property in properties {
                var value = Float32(level)
                let status = AudioObjectSetPropertyData(device.id, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
                if status != noErr { return .hardware(status) }
            }
            // 设备可能按 dB 步进量化或只接受分声道写入；实际值由随后的读回刷新展示，不按固定容差判失败。
            return nil
        }
        if let result { throw result }
    }

    public func setMuted(_ muted: Bool, device: AudioDeviceInfo, direction: AudioDirection) async throws {
        let cancellation = AudioOperationCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: AudioControlError? = await execute {
                guard !cancellation.isCancelled, AudioHAL.defaultDevice(direction) == device.id,
                      AudioHAL.string(device.id, kAudioDevicePropertyDeviceUID) == device.uid else { return .routeChanged }
                let properties = AudioHAL.writableElements(device.id, direction: direction, selector: kAudioDevicePropertyMute)
                guard !properties.isEmpty else { return .unsupported }
                guard !cancellation.isCancelled else { return .routeChanged }
                // 多声道控制一旦开始写入就完成本组操作，避免中途取消造成左右声道状态不一致。
                for var property in properties {
                    var value: UInt32 = muted ? 1 : 0
                    let status = AudioObjectSetPropertyData(device.id, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
                    if status != noErr { return .hardware(status) }
                }
                return AudioHAL.muted(device.id, direction: direction) == muted ? nil : .unavailable
            }
            try Task.checkCancellation()
            if let result { throw result }
        } onCancel: { cancellation.cancel() }
    }

    public func select(_ device: AudioDeviceInfo, direction: AudioDirection) async throws {
        try Task.checkCancellation()
        guard device.canBeDefault(direction) else { throw AudioControlError.unsupported }
        let cancellation = AudioOperationCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: AudioControlError? = await execute { [selectDevice] in
                guard !cancellation.isCancelled else { return .routeChanged }
                return selectDevice(device, direction, cancellation)
            }
            try Task.checkCancellation()
            if let result { throw result }
        } onCancel: { cancellation.cancel() }
    }

    private static func selectDefaultDevice(_ device: AudioDeviceInfo, _ direction: AudioDirection, _ cancellation: AudioOperationCancellation) -> AudioControlError? {
        guard !cancellation.isCancelled,
              AudioHAL.string(device.id, kAudioDevicePropertyDeviceUID) == device.uid,
              let current = AudioHAL.devices().first(where: { $0.id == device.id }) else { return .routeChanged }
        guard current.canBeDefault(direction) else { return .unsupported }
        var property = AudioHAL.address(direction == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        var id = device.id
        // 排队期间用户可能关闭连接界面；已发出的系统写入无法撤销，尚未写入的必须跳过。
        guard !cancellation.isCancelled else { return .routeChanged }
        let status = AudioObjectSetPropertyData(AudioHAL.system, &property, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
        guard status == noErr else { return .hardware(status) }
        return AudioHAL.defaultDevice(direction) == device.id ? nil : .unavailable
    }

    // 内部诊断供资源释放验证使用；读取也在同一 HAL 队列中完成。
    func listenerCount() async -> Int {
        await execute { [self] in systemListeners.count + detailListeners.count }
    }

    private func execute<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation()) }
        }
    }

    private func bindDetails(_ snapshot: AudioHardwareSnapshot) {
        let processIDs: [AudioObjectID]
        if watchingApplications, #available(macOS 14.4, *) { processIDs = AudioHAL.ids(AudioHAL.system, kAudioHardwarePropertyProcessObjectList) ?? [] }
        else { processIDs = [] }
        let outputIDs = watchingApplications ? snapshot.devices.filter(\.hasOutput).map(\.id).sorted() : [snapshot.outputID].compactMap { $0 }
        let streams = outputIDs.flatMap { id in
            (AudioHAL.ids(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput) ?? [])
                + (AudioHAL.ids(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput) ?? [])
        }
        let deviceIDs = snapshot.devices.map(\.id).sorted()
        let key = [snapshot.outputID ?? 0, snapshot.inputID ?? 0] + processIDs.sorted() + [0] + outputIDs + [0] + streams + [0] + deviceIDs
        guard key != detailKey else { return }
        for (object, var property, listener) in detailListeners { AudioObjectRemovePropertyListenerBlock(object, &property, queue, listener) }
        detailListeners.removeAll()
        detailKey = key
        for id in deviceIDs {
            for scope in [kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput] {
                addListener(id, AudioHAL.address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: scope), detail: true)
            }
        }
        for direction: AudioDirection in [.input, .output] {
            guard let id = direction == .output ? snapshot.outputID : snapshot.inputID else { continue }
            var addresses = Set<[UInt32]>()
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                for property in AudioHAL.elements(id, direction: direction, selector: selector) + AudioHAL.writableElements(id, direction: direction, selector: selector) {
                    if addresses.insert([property.mSelector, property.mScope, property.mElement]).inserted {
                        addListener(id, property, detail: true)
                    }
                }
            }
        }
        for output in outputIDs {
            addListener(output, AudioHAL.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioDevicePropertyScopeOutput), detail: true)
            addListener(output, AudioHAL.address(kAudioDevicePropertyNominalSampleRate), detail: true)
            addListener(output, AudioHAL.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput), detail: true)
            addListener(output, AudioHAL.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput), detail: true)
        }
        for stream in streams {
            addListener(stream, AudioHAL.address(kAudioStreamPropertyStartingChannel), detail: true)
            addListener(stream, AudioHAL.address(kAudioStreamPropertyVirtualFormat), detail: true)
            addListener(stream, AudioHAL.address(kAudioStreamPropertyIsActive), detail: true)
        }
        if #available(macOS 14.4, *) {
            for id in processIDs { addListener(id, AudioHAL.address(kAudioProcessPropertyIsRunningOutput), detail: true) }
        }
    }

    private func addListener(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, detail: Bool) {
        var property = property
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.callback?() }
        guard AudioObjectAddPropertyListenerBlock(object, &property, queue, listener) == noErr else { return }
        if detail { detailListeners.append((object, property, listener)) }
        else { systemListeners.append((object, property, listener)) }
    }

    private func removeListeners() {
        for (object, var property, listener) in systemListeners + detailListeners {
            AudioObjectRemovePropertyListenerBlock(object, &property, queue, listener)
        }
        systemListeners.removeAll()
        detailListeners.removeAll()
        detailKey.removeAll()
        listening = false
    }
}
