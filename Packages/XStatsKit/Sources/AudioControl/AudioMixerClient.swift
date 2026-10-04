// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AudioDSP
import CoreAudio
import Foundation

public struct AudioMixTarget: Sendable, Equatable {
    public let id: String
    public let processObjectIDs: [UInt32]
    public let volume: AudioAppVolume
    public init(id: String, processObjectIDs: [UInt32], volume: AudioAppVolume) {
        self.id = id
        self.processObjectIDs = processObjectIDs
        self.volume = volume
    }
}

/// 内核生命周期在专用串行队列运行；版本锁只保护命令序号，不进入实时回调。
public final class AudioMixerClient: @unchecked Sendable {
    public static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }
    private let queue = DispatchQueue(label: "work.12306.xstats.audio.mixer", qos: .userInitiated)
    private let lock = NSLock()
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var revision: UInt64 = 0
    private var pipeline: AnyObject?
    // 停止失败时保留上下文；不能释放仍可能被 IOProc 使用的内存。
    private var retired: [AnyObject] = []

    public init() { queue.setSpecific(key: queueKey, value: 1) }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            if #available(macOS 14.4, *) { try? retireCurrent(); cleanRetired() }
        } else {
            queue.sync { if #available(macOS 14.4, *) { try? retireCurrent(); cleanRetired() } }
        }
    }

    public func requestAccess() async throws {
        guard #available(macOS 14.4, *) else { throw AudioControlError.unsupported }
        let error: AudioControlError? = await withCheckedContinuation { continuation in
            queue.async {
                let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
                description.name = "XStats Audio Permission"
                description.isPrivate = true
                description.muteBehavior = .unmuted
                var tap: AudioObjectID = 0
                let status = AudioHardwareCreateProcessTap(description, &tap)
                if status == noErr, tap != 0 {
                    AudioHardwareDestroyProcessTap(tap)
                    continuation.resume(returning: nil)
                } else { continuation.resume(returning: .permissionRequired) }
            }
        }
        if let error { throw error }
    }

    public func apply(_ targets: [AudioMixTarget], outputUID: String?) async throws {
        guard #available(macOS 14.4, *) else { throw AudioControlError.unsupported }
        let command = lock.withLock { revision &+= 1; return revision }
        let active = targets.filter { $0.volume.needsProcessing && !$0.processObjectIDs.isEmpty }.sorted { $0.id < $1.id }
        let error: AudioControlError? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard isCurrent(command) else { continuation.resume(returning: nil); return }
                cleanRetired()
                guard retired.isEmpty else { continuation.resume(returning: .unavailable); return }
                do {
                    if let existing = pipeline as? CoreAudioMixPipeline,
                       existing.matches(active, outputUID: outputUID) {
                        existing.setGains(active)
                    } else {
                        try retireCurrent()
                        if !active.isEmpty {
                            guard let outputUID else { throw AudioControlError.unavailable }
                            let replacement = CoreAudioMixPipeline(targets: active, outputUID: outputUID)
                            do { try replacement.start(targets: active, shouldContinue: { self.isCurrent(command) }) }
                            catch {
                                if (try? replacement.stop()) == nil { retired.append(replacement) }
                                throw error
                            }
                            guard isCurrent(command) else {
                                if (try? replacement.stop()) == nil { retired.append(replacement) }
                                continuation.resume(returning: nil)
                                return
                            }
                            pipeline = replacement
                        }
                    }
                    continuation.resume(returning: nil)
                } catch let error as AudioControlError { continuation.resume(returning: error) }
                catch { continuation.resume(returning: .unavailable) }
            }
        }
        if let error { throw error }
    }

    public func stop() async {
        lock.withLock { revision &+= 1 }
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if #available(macOS 14.4, *) { try? retireCurrent(); cleanRetired() }
                continuation.resume()
            }
        }
    }

    /// 先停止旧输出的 IOProc，再允许调用方修改默认输出；原始声音在过渡期间由静音 tap 保护。
    public func prepareOutputSwitch() async throws -> UInt32? {
        guard #available(macOS 14.4, *) else { return nil }
        lock.withLock { revision &+= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                cleanRetired()
                guard retired.isEmpty else {
                    continuation.resume(throwing: AudioControlError.unavailable)
                    return
                }
                var guardTap: AudioObjectID = 0
                do {
                    if let current = pipeline as? CoreAudioMixPipeline {
                        let description = CATapDescription(stereoMixdownOfProcesses: current.processIDs)
                        description.name = "XStats Output Transition"
                        description.isPrivate = true
                        description.muteBehavior = .muted
                        let status = AudioHardwareCreateProcessTap(description, &guardTap)
                        guard status == noErr, guardTap != 0 else { throw AudioControlError.hardware(status) }
                        try retireCurrent()
                    }
                    continuation.resume(returning: guardTap == 0 ? nil : guardTap)
                } catch {
                    if guardTap != 0 { AudioHardwareDestroyProcessTap(guardTap) }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func finishOutputSwitch(_ guardTap: UInt32?) async {
        guard #available(macOS 14.4, *), let guardTap else { return }
        await withCheckedContinuation { continuation in
            queue.async { AudioHardwareDestroyProcessTap(guardTap); continuation.resume() }
        }
    }

    private func isCurrent(_ command: UInt64) -> Bool { lock.withLock { revision == command } }

    @available(macOS 14.4, *)
    private func retireCurrent() throws {
        guard let current = pipeline as? CoreAudioMixPipeline else { return }
        do { try current.stop(); pipeline = nil }
        catch { pipeline = nil; retired.append(current); throw error }
    }

    @available(macOS 14.4, *)
    private func cleanRetired() {
        retired.removeAll { object in
            guard let object = object as? CoreAudioMixPipeline else { return true }
            return (try? object.stop()) != nil
        }
    }
}

/// 一条私有 aggregate 输出多个应用 tap；生命周期只在 mixer.queue 中执行。
@available(macOS 14.4, *)
private final class CoreAudioMixPipeline {
    let outputUID: String
    let processIDs: [AudioObjectID]
    private let graph: [(String, [UInt32])]
    private var taps: [AudioObjectID] = []
    private var descriptions: [CATapDescription] = []
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var context: XSVolumeRendererRef?
    private var running = false
    private var streamSignature: [UInt64] = []

    init(targets: [AudioMixTarget], outputUID: String) {
        self.outputUID = outputUID
        self.processIDs = targets.flatMap(\.processObjectIDs)
        self.graph = targets.map { ($0.id, $0.processObjectIDs) }
    }

    func start(targets: [AudioMixTarget], shouldContinue: () -> Bool) throws {
        guard let output = (AudioHAL.ids(AudioHAL.system, kAudioHardwarePropertyDevices) ?? [])
            .first(where: { AudioHAL.string($0, kAudioDevicePropertyDeviceUID) == outputUID }),
              let streams = AudioHAL.ids(output, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput),
              !streams.isEmpty else { throw AudioControlError.unsupportedFormat }
        streamSignature = Self.signature(outputUID: outputUID) ?? []
        var streamIndex: Int?
        var outputOffset: UInt32 = 0
        var cursor: UInt32 = 0
        var selectedFormat: AudioStreamBasicDescription?
        for (index, stream) in streams.enumerated() {
            guard let format = Self.format(stream, selector: kAudioStreamPropertyVirtualFormat) else { throw AudioControlError.unsupportedFormat }
            if streamIndex == nil, AudioHAL.uint(stream, kAudioStreamPropertyIsActive) == 1 {
                streamIndex = index; outputOffset = cursor; selectedFormat = format
            }
            cursor += format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? format.mChannelsPerFrame : 1
        }
        guard let streamIndex, let selectedFormat else { throw AudioControlError.unsupportedFormat }
        var configurations: [XSVolumeRoute] = []
        var inputOffset: UInt32 = 0
        var expectedTapChannels: [UInt32] = []
        for target in targets {
            guard shouldContinue() else { throw AudioControlError.unavailable }
            let description = CATapDescription(processes: target.processObjectIDs, deviceUID: outputUID, stream: UInt(streamIndex))
            description.name = "XStats \(target.id)"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            var tap: AudioObjectID = 0
            let status = AudioHardwareCreateProcessTap(description, &tap)
            guard status == noErr, tap != 0 else { throw AudioControlError.hardware(status) }
            taps.append(tap)
            descriptions.append(description)
            guard let format = Self.format(tap, selector: kAudioTapPropertyFormat),
                  Self.compatible(format, selectedFormat) else { throw AudioControlError.unsupportedFormat }
            let count = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? format.mChannelsPerFrame : 1
            configurations.append(XSVolumeRoute(pcm: format, sourceBufferIndex: inputOffset,
                channelBufferCount: count, destinationBufferIndex: outputOffset, startingVolume: target.volume.gain))
            expectedTapChannels += Array(repeating: count == 1 ? format.mChannelsPerFrame : 1, count: Int(count))
            inputOffset += count
        }
        let definition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "XStats Audio Mixer",
            kAudioAggregateDeviceUIDKey: "XStats.Audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: descriptions.map {
                [kAudioSubTapUIDKey: $0.uuid.uuidString, kAudioSubTapDriftCompensationKey: false] as [String: Any]
            }
        ]
        let status = AudioHardwareCreateAggregateDevice(definition as CFDictionary, &aggregate)
        guard status == noErr, aggregate != 0 else { throw AudioControlError.hardware(status) }
        // aggregate 创建成功不代表流已就绪。等待有界，并在每次等待前响应新命令。
        for attempt in 0..<30 {
            guard shouldContinue() else { throw AudioControlError.unavailable }
            if AudioHAL.uint(aggregate, kAudioDevicePropertyDeviceIsAlive) == 1 { break }
            guard attempt < 29 else { throw AudioControlError.unavailable }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let hardwareChannels = AudioHAL.bufferChannels(output, direction: .input) ?? []
        let hardwareStreams = AudioHAL.ids(output, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput) ?? []
        guard let inputChannels = AudioHAL.bufferChannels(aggregate, direction: .input),
              let aggregateStreams = AudioHAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput),
              inputChannels == hardwareChannels + expectedTapChannels,
              aggregateStreams.count == hardwareStreams.count + targets.count else { throw AudioControlError.unsupportedFormat }
        // 双工设备的物理麦克风输入在 tap 之前；跳过它们，不把声音意外路由回扬声器。
        for index in configurations.indices { configurations[index].sourceBufferIndex += UInt32(hardwareChannels.count) }
        context = configurations.withUnsafeBufferPointer { XSVolumeRendererCreate($0.baseAddress!, $0.count) }
        guard let context else { throw AudioControlError.unavailable }
        let create = AudioDeviceCreateIOProcID(aggregate, XSVolumeRender, UnsafeMutableRawPointer(context), &ioProc)
        guard create == noErr, let ioProc else { throw AudioControlError.hardware(create) }
        let inputUsage = XStatsSetAudioInputUsage(aggregate, ioProc, UInt32(hardwareStreams.count), UInt32(aggregateStreams.count))
        guard inputUsage == noErr else { throw AudioControlError.hardware(inputUsage) }
        guard shouldContinue() else { throw AudioControlError.unavailable }
        let start = AudioDeviceStart(aggregate, ioProc)
        guard start == noErr else { throw AudioControlError.hardware(start) }
        running = true
    }

    func matches(_ targets: [AudioMixTarget], outputUID: String?) -> Bool {
        guard outputUID == self.outputUID, targets.count == graph.count,
              Self.signature(outputUID: self.outputUID) == streamSignature else { return false }
        return zip(targets, graph).allSatisfy { $0.id == $1.0 && $0.processObjectIDs == $1.1 }
    }

    func setGains(_ targets: [AudioMixTarget]) {
        guard let context else { return }
        for (index, target) in targets.enumerated() { XSVolumeRendererSetVolume(context, index, target.volume.gain) }
    }

    func stop() throws {
        if let ioProc {
            if running {
                let status = AudioDeviceStop(aggregate, ioProc)
                guard Self.removed(status) else { throw AudioControlError.hardware(status) }
                running = false
            }
            let status = AudioDeviceDestroyIOProcID(aggregate, ioProc)
            guard Self.removed(status) else { throw AudioControlError.hardware(status) }
            self.ioProc = nil
        }
        if let context { XSVolumeRendererDestroy(context); self.context = nil }
        if aggregate != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            guard Self.removed(status) else { throw AudioControlError.hardware(status) }
            aggregate = 0
        }
        for index in taps.indices where taps[index] != 0 {
            let status = AudioHardwareDestroyProcessTap(taps[index])
            guard Self.removed(status) else { throw AudioControlError.hardware(status) }
            taps[index] = 0
        }
        descriptions.removeAll()
    }

    private static func removed(_ status: OSStatus) -> Bool { status == noErr || status == kAudioHardwareBadDeviceError || status == kAudioHardwareBadObjectError }

    private static func format(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> AudioStreamBasicDescription? {
        var property = AudioHAL.address(selector)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &format) == noErr ? format : nil
    }

    /// 不只比较设备 UID：采样率或流布局变更后旧回调格式必须失效。
    private static func signature(outputUID: String) -> [UInt64]? {
        guard let output = (AudioHAL.ids(AudioHAL.system, kAudioHardwarePropertyDevices) ?? [])
            .first(where: { AudioHAL.string($0, kAudioDevicePropertyDeviceUID) == outputUID }),
              AudioHAL.uint(output, kAudioDevicePropertyDeviceIsAlive) == 1 else { return nil }
        var result: [UInt64] = []
        // 双工设备的输入流也会改变 tap 的缓冲区偏移，必须一并使管线失效。
        for scope in [kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput] {
            let streams: [UInt32]
            if let found = AudioHAL.ids(output, kAudioDevicePropertyStreams, scope: scope) { streams = found }
            else if scope == kAudioDevicePropertyScopeInput { streams = [] }
            else { return nil }
            result.append(UInt64(scope))
            for stream in streams {
                guard let format = format(stream, selector: kAudioStreamPropertyVirtualFormat) else { return nil }
                result += [UInt64(stream), UInt64(AudioHAL.uint(stream, kAudioStreamPropertyIsActive) ?? 0), format.mSampleRate.bitPattern,
                           UInt64(format.mFormatID), UInt64(format.mFormatFlags), UInt64(format.mBytesPerFrame),
                           UInt64(format.mChannelsPerFrame), UInt64(format.mBitsPerChannel)]
            }
        }
        return result
    }

    private static func compatible(_ tap: AudioStreamBasicDescription, _ output: AudioStreamBasicDescription) -> Bool {
        guard tap.mFormatID == kAudioFormatLinearPCM, output.mFormatID == tap.mFormatID,
              tap.mChannelsPerFrame > 0, tap.mChannelsPerFrame <= 32,
              tap.mSampleRate.isFinite, tap.mSampleRate > 0, tap.mSampleRate == output.mSampleRate,
              tap.mChannelsPerFrame == output.mChannelsPerFrame, tap.mBitsPerChannel == output.mBitsPerChannel,
              tap.mFormatFlags == output.mFormatFlags, tap.mBytesPerFrame == output.mBytesPerFrame else { return false }
        // C 回调仅为 24 位整数提供显式字节序处理，其他格式要求本机字节序。
        if tap.mBitsPerChannel != 24, tap.mFormatFlags & kAudioFormatFlagIsBigEndian != 0 { return false }
        let channelsPerBuffer: UInt32 = tap.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : tap.mChannelsPerFrame
        let bytesPerSample = tap.mBytesPerFrame / channelsPerBuffer
        guard tap.mFramesPerPacket == 1, tap.mBytesPerPacket == tap.mBytesPerFrame,
              tap.mBytesPerFrame % channelsPerBuffer == 0 else { return false }
        if tap.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            return [32, 64].contains(tap.mBitsPerChannel) && bytesPerSample == tap.mBitsPerChannel / 8
        }
        guard tap.mBitsPerChannel == 24 ? [3, 4].contains(bytesPerSample) : bytesPerSample == tap.mBitsPerChannel / 8 else { return false }
        return tap.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && [16, 24, 32].contains(tap.mBitsPerChannel)
    }
}
