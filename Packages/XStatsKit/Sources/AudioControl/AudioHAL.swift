// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CoreAudio
import Foundation

/// 无状态 HAL 读取与地址工具；调用方在各自的串行生命周期队列中使用，不将原生对象送到主线程。
enum AudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> UInt32? {
        var property = address(selector, scope: scope, element: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    static func scalar(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) -> Float32? {
        var property = property
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<Float32>.size, value.isFinite else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
        }
        return status == noErr ? value as String? : nil
    }

    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr,
              size <= 65_536, size % 4 == 0 else { return nil }
        guard size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        let capacity = size
        let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr, size <= capacity, size % 4 == 0 else { return nil }
        return Array(values.prefix(Int(size) / 4))
    }

    /// StreamConfiguration 是 IOProc 的真实缓冲区布局；不能用声道数猜测 buffer 索引。
    static func bufferChannels(_ object: AudioObjectID, direction: AudioDirection) -> [UInt32]? {
        var property = address(kAudioDevicePropertyStreamConfiguration,
                               scope: direction == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        let headerSize = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr,
              size >= headerSize, size <= 65_536 else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let capacity = size
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, memory) == noErr, size <= capacity else { return nil }
        let list = memory.assumingMemoryBound(to: AudioBufferList.self)
        guard list.pointee.mNumberBuffers <= 1024,
              headerSize + Int(list.pointee.mNumberBuffers) * MemoryLayout<AudioBuffer>.size <= Int(size) else { return nil }
        return UnsafeMutableAudioBufferListPointer(list).map(\.mNumberChannels)
    }

    static func settable(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) -> Bool {
        var property = property
        var value = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(object, &property, &value) == noErr && value.boolValue
    }

    static func elements(_ object: AudioObjectID, direction: AudioDirection, selector: AudioObjectPropertySelector) -> [AudioObjectPropertyAddress] {
        let scope = direction == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        let main = address(selector, scope: scope)
        var query = main
        if AudioObjectHasProperty(object, &query) { return [main] }
        // 仅回退到设备明确提供的声道，不假定所有硬件都具有两个音量控制。
        return (1...32).compactMap { channel in
            let candidate = address(selector, scope: scope, element: UInt32(channel))
            var query = candidate
            return AudioObjectHasProperty(object, &query) ? candidate : nil
        }
    }

    static func writableElements(_ object: AudioObjectID, direction: AudioDirection, selector: AudioObjectPropertySelector) -> [AudioObjectPropertyAddress] {
        let scope = direction == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        let main = address(selector, scope: scope)
        if settable(object, main) { return [main] }
        // 某些设备的主音量只读，实际可写控制在各声道上。
        return (1...32).compactMap { channel in
            let candidate = address(selector, scope: scope, element: UInt32(channel))
            return settable(object, candidate) ? candidate : nil
        }
    }

    static func volume(_ object: AudioObjectID, direction: AudioDirection) -> Double? {
        let values = elements(object, direction: direction, selector: kAudioDevicePropertyVolumeScalar).compactMap { scalar(object, $0) }
        guard !values.isEmpty else { return nil }
        return min(1, max(0, Double(values.reduce(0, +)) / Double(values.count)))
    }

    static func muted(_ object: AudioObjectID, direction: AudioDirection) -> Bool? {
        let properties = elements(object, direction: direction, selector: kAudioDevicePropertyMute)
        let values = properties.compactMap { uint(object, $0.mSelector, scope: $0.mScope, element: $0.mElement) }
        return values.isEmpty ? nil : values.allSatisfy { $0 != 0 }
    }

    static func defaultDevice(_ direction: AudioDirection) -> AudioObjectID? {
        uint(system, direction == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func devices() -> [AudioDeviceInfo] {
        (ids(system, kAudioHardwarePropertyDevices) ?? []).compactMap { id in
            guard uint(id, kAudioDevicePropertyDeviceIsAlive) == 1,
                  uint(id, kAudioDevicePropertyIsHidden) != 1,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("XStats.Audio.") else { return nil }
            let input = !(ids(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput) ?? []).isEmpty
            let output = !(ids(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput) ?? []).isEmpty
            guard input || output else { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                hasInput: input, hasOutput: output, inputVolume: volume(id, direction: .input), outputVolume: volume(id, direction: .output),
                inputMuted: muted(id, direction: .input), outputMuted: muted(id, direction: .output),
                canSetInputVolume: !writableElements(id, direction: .input, selector: kAudioDevicePropertyVolumeScalar).isEmpty,
                canSetOutputVolume: !writableElements(id, direction: .output, selector: kAudioDevicePropertyVolumeScalar).isEmpty,
                canSetInputMute: !writableElements(id, direction: .input, selector: kAudioDevicePropertyMute).isEmpty,
                canSetOutputMute: !writableElements(id, direction: .output, selector: kAudioDevicePropertyMute).isEmpty)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func applications() -> [AudioApplication] {
        guard #available(macOS 14.4, *) else { return [] }
        var groups: [String: (name: String, url: URL?, ids: [AudioObjectID])] = [:]
        for object in ids(system, kAudioHardwarePropertyProcessObjectList) ?? [] {
            guard uint(object, kAudioProcessPropertyIsRunningOutput) == 1,
                  let pid = uint(object, kAudioProcessPropertyPID), pid != UInt32(ProcessInfo.processInfo.processIdentifier),
                  let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { continue }
            var url = app.bundleURL
            // 浏览器等辅助进程归到最外层应用包，避免给同一应用显示多个滑杆。
            if let child = url {
                var ancestor = child.deletingLastPathComponent()
                for _ in 0..<24 {
                    if ancestor.pathExtension == "app" { url = ancestor }
                    let parent = ancestor.deletingLastPathComponent()
                    if parent == ancestor { break }
                    ancestor = parent
                }
            }
            let bundle = url.flatMap(Bundle.init(url:))
            let identifier = bundle?.bundleIdentifier ?? app.bundleIdentifier ?? "pid:\(pid):\(object)"
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? app.localizedName ?? identifier
            if var existing = groups[identifier] { existing.ids.append(object); groups[identifier] = existing }
            else { groups[identifier] = (name, url, [object]) }
        }
        return groups.map { AudioApplication(id: $0.key, name: $0.value.name, bundleURL: $0.value.url,
                                             processObjectIDs: $0.value.ids.sorted()) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
