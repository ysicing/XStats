// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AudioDSP
import CoreAudio
import Foundation

public struct AudioMixTarget: Sendable, Equatable {
    public let id: String
    public let processObjectIDs: [UInt32]
    public let volume: AudioAppVolume
    public let outputUID: String?
    public init(id: String, processObjectIDs: [UInt32], volume: AudioAppVolume, outputUID: String? = nil) {
        self.id = id; self.processObjectIDs = processObjectIDs; self.volume = volume; self.outputUID = outputUID
    }
}

/// 管线仅在生命周期队列访问；接口同时用于不触碰真实音频设备的故障注入测试。
protocol AudioMixPipeline: AudioResource {
    var processIDs: [UInt32] { get }
    var frameCount: UInt64 { get }
    var outputUID: String { get }
    var isOutputPresent: Bool { get }
    func matches(_ target: AudioMixTarget, outputUID: String, sourceUID: String?) -> Bool
    func start(shouldContinue: () -> Bool) throws
    func setVolume(_ volume: Float)
}

private struct AudioRenderConfiguration: Equatable {
    let objects: [UInt32]
    let outputUID: String
    let sourceUID: String?
    let format: [UInt64]
}

/// HAL 生命周期串行执行，实时回调通过无锁原子接收增益并汇报帧数。
public final class AudioMixerClient: @unchecked Sendable {
    /// 包含暂停宽限期中的应用；路由替换最多额外创建一条零增益的过渡管线。
    public static let maximumProcessedApplications = 8
    public static var isSupported: Bool { if #available(macOS 14.4, *) { return true }; return false }
    private let queue = DispatchQueue(label: "work.12306.xstats.audio.mixer", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var pipelines: [String: any AudioMixPipeline] = [:]
    private var retired: [any AudioResource] = []
    private var cleanupAttempts = 0
    private var targets: [String: AudioMixTarget] = [:]
    private var sourceUID: String?
    private var health: [String: AudioRenderHealth] = [:]
    private var failed: [String: (configuration: AudioRenderConfiguration, error: AudioControlError)] = [:]
    private var pendingReplacements: Set<String> = []
    private var timer: DispatchSourceTimer?
    private var failureHandler: (@Sendable (AudioControlError?) -> Void)?
    private let factory: @Sendable (AudioMixTarget, String, String?) throws -> any AudioMixPipeline
    private let automaticHealthChecks: Bool
    private let outputGuardFactory: @Sendable ([UInt32]) throws -> any AudioOutputSwitchGuard
    private let accessProbeFactory: @Sendable () throws -> any AudioAccessProbe
    private var outputGuards: [UInt32: any AudioOutputSwitchGuard] = [:]
    private var outputSwitchSlots: (guardID: UInt32, applications: Set<String>)?

    public convenience init() {
        self.init(automaticHealthChecks: true) { target, output, source in
            guard #available(macOS 14.4, *) else { throw AudioControlError.unsupported }
            return CoreAudioMixPipeline(target: target, outputUID: output, sourceUID: source)
        }
    }
    init(automaticHealthChecks: Bool,
         outputGuardFactory: @escaping @Sendable ([UInt32]) throws -> any AudioOutputSwitchGuard = { processes in
             guard #available(macOS 14.4, *) else { throw AudioControlError.unsupported }
             return try CoreAudioOutputSwitchGuard(processes: processes)
         },
         accessProbeFactory: @escaping @Sendable () throws -> any AudioAccessProbe = {
             guard #available(macOS 14.4, *) else { throw AudioControlError.unsupported }
             return CoreAudioAccessProbe()
         },
         factory: @escaping @Sendable (AudioMixTarget, String, String?) throws -> any AudioMixPipeline) {
        self.factory = factory; self.automaticHealthChecks = automaticHealthChecks
        self.outputGuardFactory = outputGuardFactory; self.accessProbeFactory = accessProbeFactory
        queue.setSpecific(key: queueKey, value: 1)
    }
    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil { releaseAll(scheduleCleanup: false) }
        else { queue.sync { releaseAll(scheduleCleanup: false) } }
    }

    public func setFailureHandler(_ handler: @escaping @Sendable (AudioControlError?) -> Void) {
        queue.async { [self] in failureHandler = handler }
    }
    public func requestAccess() async throws {
        guard #available(macOS 14.4, *) else { throw AudioControlError.unsupported }
        let command = lock.withLock { revision &+= 1; return revision }
        let cancellation = AudioOperationCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    guard isCurrent(command), !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    cleanRetired(resetBudget: true)
                    guard retired.isEmpty else { continuation.resume(throwing: AudioControlError.unavailable); return }
                    let probe: any AudioAccessProbe
                    do { probe = try accessProbeFactory() }
                    catch { continuation.resume(throwing: error); return }
                    var failure: (any Error)?
                    do {
                        try probe.start { self.isCurrent(command) && !cancellation.isCancelled }
                        if !isCurrent(command) || cancellation.isCancelled { throw CancellationError() }
                    } catch { failure = error }
                    if let cleanupFailure = releaseResource(probe) {
                        failure = failure ?? cleanupFailure
                        failureHandler?(.unavailable)
                    }
                    updateTimer()
                    if let failure { continuation.resume(throwing: failure) }
                    else { continuation.resume() }
                }
            }
            try Task.checkCancellation()
        } onCancel: { cancellation.cancel() }
    }

    public func apply(_ requested: [AudioMixTarget], outputUID: String?) async throws {
        guard Self.isSupported else { throw AudioControlError.unsupported }
        let command = lock.withLock { revision &+= 1; return revision }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard isCurrent(command) else { continuation.resume(); return }
                cleanRetired()
                let active = requested.filter { !$0.processObjectIDs.isEmpty && ($0.volume.needsProcessing || $0.outputUID.map { $0 != outputUID } == true) }
                // 输入经过控制器按应用归并，但外部调用方也不能用重复 ID 崩溃整个进程。
                targets = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
                sourceUID = outputUID
                for id in Array(pipelines.keys) where targets[id] == nil { retire(id); health.removeValue(forKey: id) }
                failed = failed.filter { targets[$0.key] != nil }
                pendingReplacements = pendingReplacements.filter { targets[$0] != nil }
                var failure: (any Error)? = retired.isEmpty ? nil : AudioControlError.unavailable
                // 系统输出切换会先拆掉管线；重建时仍优先恢复切换前已占用的名额。
                let reserved = outputSwitchSlots?.applications ?? []
                let ordered = targets.values.sorted {
                    let first = reserved.contains($0.id), second = reserved.contains($1.id)
                    return first == second ? $0.id < $1.id : first
                }
                for target in ordered {
                    guard isCurrent(command) else { break }
                    guard let destination = target.outputUID ?? outputUID else { failure = AudioControlError.unavailable; continue }
                    let configuration = AudioRenderConfiguration(objects: target.processObjectIDs, outputUID: destination, sourceUID: outputUID, format: AudioHAL.streamSignature(destination) ?? [])
                    // 失败缓存只限制重建；保留的旧路由仍须即时响应静音和音量，且不重置重试预算。
                    pipelines[target.id]?.setVolume(target.volume.gain)
                    if let blocked = failed[target.id], blocked.configuration == configuration,
                       blocked.error != .processingLimit(Self.maximumProcessedApplications) { continue }
                    failed.removeValue(forKey: target.id)
                    if let existing = pipelines[target.id], existing.matches(target, outputUID: destination, sourceUID: outputUID) {
                        pendingReplacements.remove(target.id); continue
                    }
                    if !retired.isEmpty { pendingReplacements.insert(target.id); failure = AudioControlError.unavailable; continue }
                    pendingReplacements.remove(target.id)
                    do { try replace(target, destination: destination, command: command, now: Self.now) }
                    catch {
                        var targetFailure: (any Error)? = error
                        if error as? AudioControlError == .renderStalled, isCurrent(command), retired.isEmpty {
                            do { try replace(target, destination: destination, command: command, now: Self.now); targetFailure = nil }
                            catch { targetFailure = error }
                        }
                        if let targetFailure, isCurrent(command) {
                            let issue = targetFailure as? AudioControlError ?? .unavailable
                            failed[target.id] = (configuration, issue)
                            failure = targetFailure
                        }
                        // 输出断开时释放旧 tap；其他失败仍保留可工作的旧路由，避免把所有声音一起切断。
                        if let old = pipelines[target.id], !old.isOutputPresent {
                            retire(target.id); health.removeValue(forKey: target.id)
                        }
                    }
                }
                updateTimer()
                if let id = failed.keys.sorted().first, let issue = failed[id]?.error { failure = issue; failureHandler?(issue) }
                else if failure == nil { failureHandler?(nil) }
                if let failure, isCurrent(command) { continuation.resume(throwing: failure) }
                else { continuation.resume() }
            }
        }
    }

    /// 新管线先以零增益启动；首个有效回调到达后停旧管线，再渐变到用户音量，避免双重播放。
    private func replace(_ target: AudioMixTarget, destination: String, command: UInt64, now: Double) throws {
        guard retired.isEmpty else { throw AudioControlError.unavailable }
        // 不挤掉已有控制；超限不创建 HAL 资源，名额释放后的下一次 apply 可重新尝试。
        guard pipelines[target.id] != nil || pipelines.count < Self.maximumProcessedApplications else {
            throw AudioControlError.processingLimit(Self.maximumProcessedApplications)
        }
        let replacement = try factory(target, destination, sourceUID)
        do {
            try replacement.start(shouldContinue: { self.isCurrent(command) })
            for attempt in 0..<150 {
                guard isCurrent(command) else { throw AudioControlError.unavailable }
                if replacement.frameCount > 0 { break }
                guard attempt < 149 else { throw AudioControlError.renderStalled }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if let previous = pipelines[target.id] {
                // HAL 拒绝停旧管线时，不激活新声音；保留旧上下文供后续安全回收。
                try previous.stop()
            }
            replacement.setVolume(target.volume.gain)
            pipelines[target.id] = replacement
            health[target.id] = AudioRenderHealth(frames: replacement.frameCount, now: now)
        } catch {
            if (try? replacement.stop()) == nil { retired.append(replacement); cleanupAttempts = 0 }
            throw error
        }
    }

    public func retryFailed() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in failed.removeAll(); health.removeAll(); cleanRetired(resetBudget: true); updateTimer(); failureHandler?(retired.isEmpty ? nil : .unavailable); continuation.resume() }
        }
    }

    /// 返回尚未落实到目标管线的应用，批量操作报错不能代替每个应用的实际结果。
    /// 在生命周期队列读取，也包含等待旧管线回收的输出切换。
    public func unresolvedApplicationIDs() async -> Set<String> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let unresolved = Set(targets.values.compactMap { target -> String? in
                    guard failed[target.id] == nil, !pendingReplacements.contains(target.id),
                          let destination = target.outputUID ?? sourceUID,
                          let pipeline = pipelines[target.id],
                          pipeline.matches(target, outputUID: destination, sourceUID: sourceUID) else { return target.id }
                    return nil
                })
                continuation.resume(returning: unresolved)
            }
        }
    }
    public func stop() async {
        lock.withLock { revision &+= 1 }
        await withCheckedContinuation { continuation in queue.async { [self] in releaseAll(); continuation.resume() } }
    }
    /// 包含当前原声直通、但切换后必须继续留在固定输出上的应用。
    public func prepareOutputSwitch(additionalProcessIDs: [UInt32] = []) async throws -> UInt32? {
        guard #available(macOS 14.4, *) else { return nil }
        lock.withLock { revision &+= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                cleanRetired()
                guard retired.isEmpty else { continuation.resume(throwing: AudioControlError.unavailable); return }
                let objects = Set(pipelines.values.flatMap(\.processIDs) + additionalProcessIDs).sorted()
                guard !objects.isEmpty else { continuation.resume(returning: nil); return }
                let resource: any AudioOutputSwitchGuard
                do { resource = try outputGuardFactory(objects) }
                catch { continuation.resume(throwing: error); return }
                outputGuards[resource.id] = resource
                releaseAll(preservingOutputGuard: resource.id)
                guard retired.isEmpty else {
                    try? releaseOutputGuard(resource.id)
                    updateTimer()
                    continuation.resume(throwing: AudioControlError.unavailable); return
                }
                continuation.resume(returning: resource.id)
            }
        }
    }
    public func finishOutputSwitch(_ tap: UInt32?) async throws {
        guard #available(macOS 14.4, *), let tap else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                // 已取消操作可能晚到；只有所属 guard 的收尾才撤销本次预留。
                defer { if outputSwitchSlots?.guardID == tap { outputSwitchSlots = nil } }
                do { try releaseOutputGuard(tap); updateTimer(); continuation.resume() }
                catch { failureHandler?(.unavailable); updateTimer(); continuation.resume(throwing: error) }
            }
        }
    }

    /// 所有停止失败的资源转移到 retired，不能因为调用方丢弃句柄而遗失原生对象。
    private func releaseResource(_ resource: any AudioResource) -> (any Error)? {
        do { try resource.stop(); return nil }
        catch { retired.append(resource); cleanupAttempts = 0; return error }
    }

    private func releaseOutputGuard(_ id: UInt32) throws {
        guard let resource = outputGuards.removeValue(forKey: id) else { return }
        if let failure = releaseResource(resource) { throw failure }
    }
    private static var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    private func isCurrent(_ command: UInt64) -> Bool { lock.withLock { revision == command } }
    @discardableResult
    private func retire(_ id: String) -> Bool {
        guard let old = pipelines.removeValue(forKey: id) else { return true }
        return releaseResource(old) == nil
    }
    private func cleanRetired(resetBudget: Bool = false) {
        if resetBudget { cleanupAttempts = 0 }
        guard !retired.isEmpty, cleanupAttempts < 2 else { return }
        cleanupAttempts += 1
        retired.removeAll { (try? $0.stop()) != nil }
    }
    private func releaseAll(scheduleCleanup: Bool = true, preservingOutputGuard: UInt32? = nil) {
        outputSwitchSlots = preservingOutputGuard.map { ($0, Set(pipelines.keys)) }
        timer?.cancel(); timer = nil
        for id in Array(pipelines.keys) { retire(id) }
        for id in Array(outputGuards.keys) where id != preservingOutputGuard { try? releaseOutputGuard(id) }
        targets.removeAll(); health.removeAll(); failed.removeAll(); pendingReplacements.removeAll(); cleanRetired(resetBudget: true)
        if !retired.isEmpty { failureHandler?(.unavailable) }
        if scheduleCleanup { updateTimer() }
    }
    private func updateTimer() {
        guard automaticHealthChecks else { return }
        if pipelines.isEmpty && (retired.isEmpty || cleanupAttempts >= 2) { timer?.cancel(); timer = nil; return }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(1500), repeating: .milliseconds(1500), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.inspectHealth(now: Self.now) }
        self.timer = timer; timer.resume()
    }
    func checkHealth(now: Double) async {
        await withCheckedContinuation { continuation in queue.async { [self] in inspectHealth(now: now); continuation.resume() } }
    }
    private func inspectHealth(now: Double) {
        cleanRetired()
        if !retired.isEmpty { failureHandler?(.unavailable) }
        let command = lock.withLock { revision }
        for id in Array(pipelines.keys) {
            guard let pipe = pipelines[id], let target = targets[id] else { continue }
            var observation = health[id] ?? AudioRenderHealth(frames: pipe.frameCount, now: now)
            let action = observation.observe(frames: pipe.frameCount, now: now)
            health[id] = observation
            guard action != .wait else { continue }
            let destination = target.outputUID ?? sourceUID
            let stopped = retire(id)
            if action == .retry, stopped, retired.isEmpty, let destination {
                do {
                    try replace(target, destination: destination, command: command, now: now)
                    observation.restarted(frames: pipelines[id]?.frameCount ?? 0, now: now); health[id] = observation
                    continue
                } catch { /* 同一配置重建失败便恢复原声，不进入无限重试。 */ }
            }
            if let destination {
                failed[id] = (AudioRenderConfiguration(objects: target.processObjectIDs, outputUID: destination, sourceUID: sourceUID, format: AudioHAL.streamSignature(destination) ?? []), stopped && retired.isEmpty ? .renderStalled : .unavailable)
            }
            health.removeValue(forKey: id)
            failureHandler?(stopped && retired.isEmpty ? .renderStalled : .unavailable)
        }
        // 仅恢复明确被闸门暂缓的需求。真实启动失败须保留预算，即使清理失败也不能再次自动创建。
        if retired.isEmpty {
            for id in pendingReplacements.sorted() {
                guard retired.isEmpty else { break }
                guard let target = targets[id], let destination = target.outputUID ?? sourceUID, isCurrent(command) else { continue }
                pendingReplacements.remove(id)
                if failed[id] != nil { continue }
                if let current = pipelines[id], current.matches(target, outputUID: destination, sourceUID: sourceUID) {
                    current.setVolume(target.volume.gain); continue
                }
                do { try replace(target, destination: destination, command: command, now: now) }
                catch {
                    let issue = error as? AudioControlError ?? .unavailable
                    failed[id] = (AudioRenderConfiguration(objects: target.processObjectIDs, outputUID: destination, sourceUID: sourceUID, format: AudioHAL.streamSignature(destination) ?? []), issue)
                    failureHandler?(issue)
                }
            }
            if failed.isEmpty && pendingReplacements.isEmpty && retired.isEmpty { failureHandler?(nil) }
        }
        updateTimer()
    }
}

/// 每应用一条私有 aggregate 与 tap，支持独立输出；生命周期只在 mixer.queue 中执行。
@available(macOS 14.4, *)
private final class CoreAudioMixPipeline: AudioMixPipeline {
    let outputUID: String
    let processIDs: [AudioObjectID]
    private let graph: [(String, [UInt32])]
    private let target: AudioMixTarget
    private let sourceUID: String?
    var frameCount: UInt64 { context.map(XSVolumeRendererFrameCount) ?? 0 }
    var isOutputPresent: Bool { AudioHAL.devices().contains { $0.uid == outputUID && $0.hasOutput } }
    private var taps: [AudioObjectID] = []
    private var descriptions: [CATapDescription] = []
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var context: XSVolumeRendererRef?
    private var running = false
    private var streamSignature: [UInt64] = []

    init(target: AudioMixTarget, outputUID: String, sourceUID: String?) {
        self.target = target; self.sourceUID = sourceUID; self.outputUID = outputUID
        self.processIDs = target.processObjectIDs; self.graph = [(target.id, target.processObjectIDs)]
    }
    func start(shouldContinue: () -> Bool) throws {
        let targets = [target]
        guard let output = (AudioHAL.ids(AudioHAL.system, kAudioHardwarePropertyDevices) ?? [])
            .first(where: { AudioHAL.string($0, kAudioDevicePropertyDeviceUID) == outputUID }),
              let streams = AudioHAL.ids(output, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput),
              !streams.isEmpty else { throw AudioControlError.unsupportedFormat }
        streamSignature = AudioHAL.streamSignature( outputUID) ?? []
        var outputStreams: [AudioOutputStream] = []
        var cursor: UInt32 = 0
        for stream in streams {
            guard let format = Self.format(stream, selector: kAudioStreamPropertyVirtualFormat),
                  let startingChannel = AudioHAL.uint(stream, kAudioStreamPropertyStartingChannel), startingChannel > 0,
                  (1...32).contains(format.mChannelsPerFrame) else { throw AudioControlError.unsupportedFormat }
            outputStreams.append(AudioOutputStream(startingChannel: startingChannel, bufferIndex: cursor, format: format))
            cursor += format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? format.mChannelsPerFrame : 1
        }
        let layout = try AudioOutputLayout.resolve(streams: outputStreams,
            preferred: AudioHAL.ids(output, kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioDevicePropertyScopeOutput))
        let selectedFormat = layout.format
        guard Self.supportsPCM(selectedFormat) else { throw AudioControlError.unsupportedFormat }
        var configurations: [XSVolumeRoute] = []
        var inputOffset: UInt32 = 0
        var expectedTapChannels: [UInt32] = []
        for target in targets {
            guard shouldContinue() else { throw AudioControlError.unavailable }
            let description = CATapDescription(stereoMixdownOfProcesses: target.processObjectIDs)
            description.name = "XStats \(target.id)"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            var tap: AudioObjectID = 0
            let status = AudioHardwareCreateProcessTap(description, &tap)
            guard status == noErr, tap != 0 else { throw AudioControlError.hardware(status) }
            taps.append(tap)
            descriptions.append(description)
            guard let format = Self.format(tap, selector: kAudioTapPropertyFormat),
                  Self.supportsPCM(format) else { throw AudioControlError.unsupportedFormat }
            let count = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? format.mChannelsPerFrame : 1
            configurations.append(XSVolumeRoute(pcm: format, sourceBufferIndex: inputOffset,
                channelBufferCount: count, destinationBufferIndex: layout.bufferIndex, startingVolume: 0, outputPCM: selectedFormat,
                leftOutputChannel: layout.leftChannel, rightOutputChannel: layout.rightChannel))
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
                [kAudioSubTapUIDKey: $0.uuid.uuidString, kAudioSubTapDriftCompensationKey: true] as [String: Any]
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
              aggregateStreams.count == hardwareStreams.count + 1,
              let tapStream = aggregateStreams.last,
              let inputFormat = Self.format(tapStream, selector: kAudioStreamPropertyVirtualFormat),
              Self.supportsPCM(inputFormat), inputFormat.mSampleRate == selectedFormat.mSampleRate else { throw AudioControlError.unsupportedFormat }
        let planar = inputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let tapBuffers = planar ? inputFormat.mChannelsPerFrame : 1
        guard inputChannels == hardwareChannels + Array(repeating: planar ? 1 : inputFormat.mChannelsPerFrame, count: Int(tapBuffers)) else { throw AudioControlError.unsupportedFormat }
        configurations[0].pcm = inputFormat
        configurations[0].channelBufferCount = tapBuffers
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

    func matches(_ target: AudioMixTarget, outputUID: String, sourceUID: String?) -> Bool {
        self.sourceUID == sourceUID && self.outputUID == outputUID && graph[0].0 == target.id
            && graph[0].1 == target.processObjectIDs && AudioHAL.streamSignature( outputUID) == streamSignature
    }
    func setVolume(_ volume: Float) { if let context { XSVolumeRendererSetVolume(context, 0, volume) } }

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

    private static func supportsPCM(_ format: AudioStreamBasicDescription) -> Bool {
        guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate.isFinite, format.mSampleRate > 0,
              (1...32).contains(format.mChannelsPerFrame) else { return false }
        return format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            ? [32, 64].contains(format.mBitsPerChannel) : [16, 24, 32].contains(format.mBitsPerChannel)
    }
}
