// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AudioDSP
import CoreAudio
import Foundation

/// 所有带 HAL 句柄的对象共用串行生命周期队列；停止失败时必须保留所有权。
protocol AudioResource: AnyObject { func stop() throws }
protocol AudioAccessProbe: AudioResource { func start(shouldContinue: () -> Bool) throws }
protocol AudioOutputSwitchGuard: AudioResource { var id: UInt32 { get } }

@available(macOS 14.4, *)
final class CoreAudioOutputSwitchGuard: AudioOutputSwitchGuard {
    let id: UInt32
    private let description: CATapDescription
    private var removed = false

    init(processes: [UInt32]) throws {
        description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "XStats Output Transition"
        description.isPrivate = true; description.muteBehavior = .muted
        var tap: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != 0 else { throw AudioControlError.hardware(status) }
        id = tap
    }

    func stop() throws {
        guard !removed else { return }
        let status = AudioHardwareDestroyProcessTap(id)
        if AudioHAL.resourceWasRemoved(status) { removed = true; return }
        // 即使 HAL 暂时拒绝销毁，也先尝试撤销过渡静音；失败句柄仍交由 mixer 保留并重试。
        description.muteBehavior = .unmuted
        var value = description
        var property = AudioHAL.address(kAudioTapPropertyDescription)
        _ = AudioObjectSetPropertyData(id, &property, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), &value)
        throw AudioControlError.hardware(status)
    }
}

/// 短暂启动真实 tap 输入以触发系统权限提示；不静音、保存或处理声音。
/// IOProc 回调只丢弃输入并汇报已运行，不能把回调出现当作系统授权状态查询。
@available(macOS 14.4, *)
final class CoreAudioAccessProbe: AudioAccessProbe {
    private var tap: AudioObjectID = 0
    private var description: CATapDescription?
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var context: XSAccessProbeRef?
    private var running = false

    func start(shouldContinue: () -> Bool) throws {
        guard shouldContinue() else { throw CancellationError() }
        guard let output = AudioHAL.defaultDevice(.output), let uid = AudioHAL.string(output, kAudioDevicePropertyDeviceUID) else { throw AudioControlError.unavailable }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "XStats Audio Permission"; description.isPrivate = true; description.muteBehavior = .unmuted
        self.description = description
        let createTap = AudioHardwareCreateProcessTap(description, &tap)
        guard createTap == noErr, tap != 0 else { throw AudioControlError.hardware(createTap) }
        guard shouldContinue() else { throw CancellationError() }
        let definition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "XStats Audio Permission",
            kAudioAggregateDeviceUIDKey: "XStats.Audio.Access.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        let createAggregate = AudioHardwareCreateAggregateDevice(definition as CFDictionary, &aggregate)
        guard createAggregate == noErr, aggregate != 0 else { throw AudioControlError.hardware(createAggregate) }
        for attempt in 0..<30 {
            guard shouldContinue() else { throw CancellationError() }
            if AudioHAL.uint(aggregate, kAudioDevicePropertyDeviceIsAlive) == 1 { break }
            guard attempt < 29 else { throw AudioControlError.unavailable }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let inputs = AudioHAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput), !inputs.isEmpty else { throw AudioControlError.unavailable }
        let hardwareInputs = AudioHAL.ids(output, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput) ?? []
        context = XSAccessProbeCreate()
        guard let context else { throw AudioControlError.unavailable }
        let createIO = AudioDeviceCreateIOProcID(aggregate, XSAccessProbeRead, UnsafeMutableRawPointer(context), &ioProc)
        guard createIO == noErr, let ioProc else { throw AudioControlError.hardware(createIO) }
        // 双工输出可能带物理麦克风输入；只启用 tap，避免额外请求麦克风权限。
        let usage = XStatsSetAudioInputUsage(aggregate, ioProc, UInt32(hardwareInputs.count), UInt32(inputs.count))
        guard usage == noErr else { throw AudioControlError.hardware(usage) }
        guard shouldContinue() else { throw CancellationError() }
        let start = AudioDeviceStart(aggregate, ioProc)
        guard start == noErr else { throw AudioControlError.hardware(start) }
        running = true
        for attempt in 0..<150 {
            guard shouldContinue() else { throw CancellationError() }
            if XSAccessProbeDidRun(context) { return }
            guard attempt < 149 else { throw AudioControlError.permissionRequired }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func stop() throws {
        if let ioProc {
            if running {
                let status = AudioDeviceStop(aggregate, ioProc)
                guard AudioHAL.resourceWasRemoved(status) else { throw AudioControlError.hardware(status) }
                running = false
            }
            let status = AudioDeviceDestroyIOProcID(aggregate, ioProc)
            guard AudioHAL.resourceWasRemoved(status) else { throw AudioControlError.hardware(status) }
            self.ioProc = nil
        }
        if let context { XSAccessProbeDestroy(context); self.context = nil }
        if aggregate != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            guard AudioHAL.resourceWasRemoved(status) else { throw AudioControlError.hardware(status) }
            aggregate = 0
        }
        if tap != 0 {
            let status = AudioHardwareDestroyProcessTap(tap)
            guard AudioHAL.resourceWasRemoved(status) else { throw AudioControlError.hardware(status) }
            tap = 0; description = nil
        }
    }
}
