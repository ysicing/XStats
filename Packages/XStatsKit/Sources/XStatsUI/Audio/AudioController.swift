// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import AudioControl
import Foundation
import Observation

/// 设备事件驱动刷新；关闭界面后仅保留已修改音量所需的应用检测与实时处理。
@MainActor @Observable
final class AudioController {
    private(set) var snapshot = AudioHardwareSnapshot.empty
    /// 用户启用偏好，不表示 macOS 已授权；系统权限始终由真实捕获操作执行时检查。
    private(set) var appVolumeEnabled: Bool
    private(set) var isWorking = false
    private(set) var isAuthorizing = false
    private(set) var switchingDevice: AudioDirection?
    private(set) var bluetoothDevices: [BluetoothAudioDevice] = []
    private(set) var connectingBluetooth: String?
    private(set) var pendingOutputApps: Set<String> = []
    private(set) var failedOutputApps: Set<String> = []
    private var operationError: AudioControlError?
    private var mixingError: AudioControlError?
    var error: AudioControlError? { operationError ?? mixingError }
    var canRetryMixing: Bool { mixingError != nil }
    private(set) var volumes: [String: AudioAppVolume]
    private(set) var outputRoutes: [String: String]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let hardware: AudioHardwareClient
    @ObservationIgnored private let mixer: AudioMixerClient
    @ObservationIgnored private let bluetooth = BluetoothAudioClient()
    @ObservationIgnored private var bluetoothRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var operationRevision: UInt64 = 0
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var menuVisible = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var mixTask: Task<Void, Never>?
    @ObservationIgnored private var mixRequests = AudioMixRequestTracker()
    @ObservationIgnored private var playbackGrace = AudioPlaybackGrace()
    @ObservationIgnored private var playbackGraceTask: Task<Void, Never>?
    @ObservationIgnored private var applicationList = AudioApplicationList()
    @ObservationIgnored private var volumeWriter: AudioDeviceVolumeWriter!
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []

    var output: AudioDeviceInfo? { snapshot.devices.first { $0.id == snapshot.outputID } }
    var input: AudioDeviceInfo? { snapshot.devices.first { $0.id == snapshot.inputID } }
    var supportsMixing: Bool { AudioMixerClient.isSupported }
    var listedApplications: [AudioApplication] { applicationList.visible(snapshot.applications, volumes: volumes, outputs: outputRoutes) }
    private var hasSavedAdjustments: Bool { volumes.values.contains(where: \.needsProcessing) || !outputRoutes.isEmpty }

    init(defaults: UserDefaults = .standard, mixer: AudioMixerClient = AudioMixerClient(), hardware: AudioHardwareClient = AudioHardwareClient()) {
        self.defaults = defaults
        self.mixer = mixer
        self.hardware = hardware
        let activationKey = "audio.appVolumeEnabled"
        let savedActivation = defaults.object(forKey: activationKey) == nil
            ? defaults.bool(forKey: "audio.captureAuthorized") : defaults.bool(forKey: activationKey)
        appVolumeEnabled = savedActivation
        defaults.set(savedActivation, forKey: activationKey)
        defaults.removeObject(forKey: "audio.captureAuthorized")
        let decoded = defaults.data(forKey: "audio.applicationVolumes")
            .flatMap { data -> [String: AudioAppVolume]? in
                guard data.count <= 262_144 else { return nil }
                return try? JSONDecoder().decode([String: AudioAppVolume].self, from: data)
            } ?? [:]
        volumes = Dictionary(uniqueKeysWithValues: decoded.sorted { $0.key < $1.key }.prefix(256).compactMap { key, value in
            guard !key.hasPrefix("pid:"), key.count <= 512, let checked = AudioAppVolume(level: value.level, isMuted: value.isMuted), checked.needsProcessing else { return nil }
            return (key, checked)
        })
        let routes = defaults.data(forKey: "audio.applicationOutputs").flatMap { data -> [String: String]? in
            guard data.count <= 524_288 else { return nil }
            return try? JSONDecoder().decode([String: String].self, from: data)
        } ?? [:]
        outputRoutes = Dictionary(uniqueKeysWithValues: routes.sorted { $0.key < $1.key }.prefix(256).filter {
            !$0.key.hasPrefix("pid:") && !$0.key.isEmpty && $0.key.count <= 512 && !$0.value.isEmpty && $0.value.count <= 512
        })
        volumeWriter = AudioDeviceVolumeWriter(write: { [hardware] request in
            try await hardware.setVolume(request.level, device: request.device, direction: request.direction)
            if request.level > 0, (request.direction == .output ? request.device.outputMuted : request.device.inputMuted) == true {
                try await hardware.setMuted(false, device: request.device, direction: request.direction)
            }
        }, finished: { [weak self] request, error in
            guard let self, enabled, !sleeping else { return }
            let currentDevice = request.direction == .output ? output : input
            guard currentDevice?.id == request.device.id, currentDevice?.uid == request.device.uid else { return }
            operationError = error
            scheduleRefresh(immediate: true)
        })
        mixer.setFailureHandler { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, enabled, !sleeping, mixTask == nil,
                      error != mixingError || !failedOutputApps.isEmpty else { return }
                let epoch = revision
                let unresolved = await mixer.unresolvedApplicationIDs()
                guard revision == epoch, enabled, !sleeping, mixTask == nil else { return }
                mixingError = error
                // 操作期间由当前 mixTask 收尾；健康检查恢复后也要撤销旧的行内失败提示。
                finishOutputSwitches(unresolved: unresolved)
            }
        }

    }

    /// 离屏走查夹具；已启用的真实控制器不能被演示状态覆盖，也不会请求权限或启动处理。
    func showPreview(_ snapshot: AudioHardwareSnapshot, volumes: [String: AudioAppVolume], outputs: [String: String], bluetoothDevices: [BluetoothAudioDevice] = []) {
        guard !enabled else { return }
        applicationList.update(snapshot.applications)
        self.snapshot = snapshot; self.volumes = volumes; outputRoutes = outputs; appVolumeEnabled = true
        self.bluetoothDevices = bluetoothDevices
    }

    func volume(for app: AudioApplication) -> AudioAppVolume { volumes[app.id] ?? AudioAppVolume(level: 1)! }

    func setDemand(enabled: Bool, visible: Bool, menuVisible: Bool) {
        guard self.enabled != enabled || self.visible != visible || self.menuVisible != menuVisible else { return }
        let wasBluetoothVisible = self.enabled && self.visible && !sleeping
        self.enabled = enabled
        self.visible = visible
        self.menuVisible = menuVisible
        revision &+= 1
        if enabled, visible, !sleeping {
            if !wasBluetoothVisible { refreshBluetoothDevices() }
        } else {
            cancelPendingAudioOperation()
            bluetoothRefreshTask?.cancel(); bluetoothRefreshTask = nil
            bluetoothDevices = []
        }
        if !enabled || sleeping { volumeWriter.cancelPending() }
        updateWatchers()
    }

    private func refreshBluetoothDevices() {
        bluetoothRefreshTask?.cancel()
        bluetoothRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let devices = try await bluetooth.pairedDevices()
                guard !Task.isCancelled, enabled, visible, !sleeping else { return }
                bluetoothDevices = devices
                if operationError == .bluetoothPermissionRequired || operationError == .bluetoothUnavailable { operationError = nil }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, enabled, visible, !sleeping else { return }
                operationError = error as? AudioControlError ?? .bluetoothUnavailable
            }
        }
    }

    private func cancelPendingAudioOperation() {
        guard operationTask != nil else { return }
        operationTask?.cancel(); operationTask = nil; operationRevision &+= 1
        connectingBluetooth = nil; switchingDevice = nil; isWorking = false; isAuthorizing = false
    }

    private func updateWatchers() {
        refreshTask?.cancel()
        let epoch = revision
        if !enabled || sleeping {
            pendingOutputApps.removeAll(); failedOutputApps.removeAll()
            switchingDevice = nil; isAuthorizing = false
            volumeWriter.cancelPending()
            hardware.stopWatching()
            mixTask?.cancel(); mixRequests.reset()
            playbackGraceTask?.cancel(); playbackGraceTask = nil; playbackGrace.reset()
            Task { [weak self] in
                guard let self, revision == epoch else { return }
                await mixer.stop()
            }
            if !enabled { applicationList.reset(); snapshot = .empty; removeSleepObservers() }
            return
        }
        installSleepObservers()
        let watchesApps = visible || (appVolumeEnabled && hasSavedAdjustments)
        if visible || menuVisible || watchesApps {
            hardware.watch(applications: watchesApps) { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
            scheduleRefresh(immediate: true)
        } else {
            hardware.stopWatching()
            Task { [weak self] in
                guard let self, revision == epoch else { return }
                await mixer.stop()
            }
        }
    }

    private func scheduleRefresh(immediate: Bool = false) {
        guard enabled, !sleeping else { return }
        refreshTask?.cancel()
        let epoch = revision
        refreshTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(80), tolerance: .milliseconds(20)) }
            guard let self, !Task.isCancelled, revision == epoch, enabled, !sleeping else { return }
            let includeApplications = visible || (appVolumeEnabled && hasSavedAdjustments)
            let updated = await hardware.snapshot(includeApplications: includeApplications)
            guard !Task.isCancelled, revision == epoch, enabled, !sleeping else { return }
            // 未采集应用目录时不能把空数组解释成连接结束；重新打开后再核对实际音频对象。
            if includeApplications { applicationList.update(updated.applications) }
            snapshot = updated
            updatePlaybackGrace()
            let currentIDs = Set(updated.applications.map(\.id))
            pendingOutputApps.formIntersection(Set(updated.applications.filter(\.isPlaying).map(\.id)))
            failedOutputApps.formIntersection(currentIDs)
            volumes = volumes.filter { !$0.key.hasPrefix("pid:") || currentIDs.contains($0.key) }
            outputRoutes = outputRoutes.filter { !$0.key.hasPrefix("pid:") || currentIDs.contains($0.key) }
            if !isWorking { reconcile() }
        }
    }

    func authorizeMixing() {
        guard enabled, !sleeping, supportsMixing, !isWorking else { return }
        perform { [self] in
            let command = operationRevision
            try await mixer.requestAccess()
            guard operationIsCurrent(command) else { throw CancellationError() }
            mixingError = nil
            appVolumeEnabled = true
            defaults.set(true, forKey: "audio.appVolumeEnabled")
            updateWatchers()
        }
        isAuthorizing = true
    }

    func setAppLevel(_ level: Double, app: AudioApplication) {
        guard enabled, !sleeping, !isWorking, appVolumeEnabled, supportsMixing, let volume = AudioAppVolume(level: level) else { return }
        operationError = nil
        save(volume, for: app.id)
        reconcile()
    }

    func toggleAppMute(_ app: AudioApplication) {
        guard enabled, !sleeping, !isWorking, appVolumeEnabled, supportsMixing else { return }
        var volume = volume(for: app)
        volume.isMuted.toggle()
        operationError = nil
        save(volume, for: app.id)
        reconcile()
    }

    func resetApp(_ app: AudioApplication) {
        guard enabled, !sleeping, !isWorking else { return }
        operationError = nil
        volumes.removeValue(forKey: app.id)
        outputRoutes.removeValue(forKey: app.id)
        pendingOutputApps.remove(app.id); failedOutputApps.remove(app.id)
        persist()
        reconcile()
        updateWatchers()
    }

    func setAppOutput(_ uid: String?, app: AudioApplication) {
        guard enabled, !sleeping, !isWorking, appVolumeEnabled, outputRoutes[app.id] != uid else { return }
        if let uid {
            guard snapshot.devices.contains(where: { $0.uid == uid && $0.hasOutput }), outputRoutes[app.id] != nil || outputRoutes.count < 256 else { return }
            outputRoutes[app.id] = uid
        } else { outputRoutes.removeValue(forKey: app.id) }
        if app.isPlaying { pendingOutputApps.insert(app.id) }
        failedOutputApps.remove(app.id)
        persist(); operationError = nil; reconcile(); updateWatchers()
    }
    func retryMixing() {
        guard enabled, !sleeping, !isWorking else { return }
        operationError = nil
        Task { [weak self] in
            guard let self else { return }
            await mixer.retryFailed()
            if enabled, !sleeping { reconcile() }
        }
    }
    private var mixTargets: [AudioMixTarget] {
        guard enabled, !sleeping, appVolumeEnabled else { return [] }
        return snapshot.applications.compactMap { app in
            guard app.isPlaying || playbackGrace.contains(app.id) else { return nil }
            let volume = volume(for: app)
            let selected = outputRoutes[app.id].flatMap { uid in snapshot.devices.contains { $0.uid == uid && $0.hasOutput } ? uid : nil }
            guard volume.needsProcessing || selected.map({ $0 != output?.uid }) == true else { return nil }
            return AudioMixTarget(id: app.id, processObjectIDs: app.processObjectIDs, volume: volume, outputUID: selected)
        }
    }
    private func save(_ volume: AudioAppVolume, for id: String) {
        guard id.count <= 512, volumes[id] != nil || volumes.count < 256 else { return }
        if volume.needsProcessing { volumes[id] = volume } else { volumes.removeValue(forKey: id) }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(volumes.filter { !$0.key.hasPrefix("pid:") }), forKey: "audio.applicationVolumes")
        defaults.set(try? JSONEncoder().encode(outputRoutes.filter { !$0.key.hasPrefix("pid:") }), forKey: "audio.applicationOutputs")
    }

    private func updatePlaybackGrace() {
        playbackGraceTask?.cancel(); playbackGraceTask = nil
        guard let expiry = playbackGrace.update(snapshot.applications, now: .now) else { return }
        let epoch = revision
        playbackGraceTask = Task { [weak self] in
            try? await Task.sleep(until: expiry, tolerance: .seconds(5))
            guard let self, !Task.isCancelled, revision == epoch, enabled, !sleeping else { return }
            updatePlaybackGrace()
            if !isWorking { reconcile() }
        }
    }

    private func reconcile() {
        let targets = mixTargets
        let uid = output?.uid
        guard let generation = mixRequests.begin(.init(targets: targets, outputUID: uid)) else { return }
        mixTask?.cancel()
        let epoch = revision
        mixTask = Task { [weak self] in
            guard let self else { return }
            defer { finishMix(generation) }
            guard !Task.isCancelled else { return }
            do {
                if supportsMixing { try await mixer.apply(targets, outputUID: uid) }
                let unresolved = await mixer.unresolvedApplicationIDs()
                guard !Task.isCancelled, revision == epoch else { return }
                mixingError = nil
                finishOutputSwitches(unresolved: unresolved)
                mixTask = nil
            } catch {
                let unresolved = await mixer.unresolvedApplicationIDs()
                guard !Task.isCancelled, revision == epoch else { return }
                finishOutputSwitches(unresolved: unresolved)
                mixTask = nil
                self.mixingError = error as? AudioControlError ?? .unavailable
                if self.mixingError == .permissionRequired {
                    appVolumeEnabled = false
                    defaults.set(false, forKey: "audio.appVolumeEnabled")
                }
            }
        }
    }

    private func finishMix(_ generation: UInt64) {
        guard mixRequests.finish(generation), enabled, !sleeping, !isWorking else { return }
        reconcile()
    }

    private func finishOutputSwitches(unresolved: Set<String>) {
        // 保留仍未落实的行；成功应用和成功重试都从实际结果清除，避免归咎整个批次。
        failedOutputApps = pendingOutputApps.union(failedOutputApps).intersection(unresolved)
        pendingOutputApps.removeAll()
    }

    func setDeviceLevel(_ level: Double, direction: AudioDirection) {
        guard enabled, !sleeping, !isWorking, let device = direction == .output ? output : input else { return }
        volumeWriter.submit(AudioDeviceVolumeRequest(level: level, device: device, direction: direction))
    }

    /// 复用最终写入的读回任务；松手后不再让草稿覆盖设备确认值。
    func finishDeviceVolumeEditing() async {
        await volumeWriter.flush()
        guard !Task.isCancelled, enabled, !sleeping else { return }
        if let refreshTask { await refreshTask.value }
    }

    func toggleDeviceMute(_ direction: AudioDirection) {
        guard !isWorking, let device = direction == .output ? output : input else { return }
        let muted = direction == .output ? device.outputMuted : device.inputMuted
        guard let muted else { return }
        perform { [hardware] in try await hardware.setMuted(!muted, device: device, direction: direction) }
    }

    func selectDevice(_ id: UInt32, direction: AudioDirection) {
        guard !isWorking, let device = snapshot.devices.first(where: { $0.id == id }) else { return }
        guard device.id != (direction == .output ? snapshot.outputID : snapshot.inputID) else { return }
        perform(switching: direction) { [self] in try await switchDevice(device, direction: direction, command: operationRevision) }
    }

    func connectBluetooth(_ id: String, direction: AudioDirection) {
        guard enabled, visible, !sleeping, !isWorking,
              let device = bluetoothDevices.first(where: { $0.id == id }) else { return }
        perform(switching: direction, bluetoothID: id) { [self] in
            let command = operationRevision
            let ready = try await bluetooth.connect(device, direction: direction)
            guard operationIsCurrent(command) else { throw CancellationError() }
            try await switchDevice(ready, direction: direction, command: command)
        }
    }

    private func operationIsCurrent(_ command: UInt64) -> Bool {
        enabled && !sleeping && !Task.isCancelled && operationRevision == command
    }

    private func switchDevice(_ device: AudioDeviceInfo, direction: AudioDirection, command: UInt64) async throws {
        guard operationIsCurrent(command) else { throw CancellationError() }
        let guardTap = direction == .output ? try await mixer.prepareOutputSwitch() : nil
        guard operationIsCurrent(command) else { try? await mixer.finishOutputSwitch(guardTap); throw CancellationError() }
        do {
            try await hardware.select(device, direction: direction)
            guard operationIsCurrent(command) else { throw CancellationError() }
            let includeApplications = appVolumeEnabled && hasSavedAdjustments || visible
            let updated = await hardware.snapshot(includeApplications: includeApplications)
            guard operationIsCurrent(command) else { throw CancellationError() }
            if includeApplications { applicationList.update(updated.applications) }
            snapshot = updated
            let targets = mixTargets
            if direction == .output, supportsMixing { try await mixer.apply(targets, outputUID: output?.uid) }
            guard operationIsCurrent(command) else { throw CancellationError() }
            try await mixer.finishOutputSwitch(guardTap)
        } catch {
            // 写设备失败时，先尝试恢复当前输出上的音量，之后才释放过渡静音。
            if operationIsCurrent(command), supportsMixing {
                let includeApplications = appVolumeEnabled
                let updated = await hardware.snapshot(includeApplications: includeApplications)
                if operationIsCurrent(command) {
                    if includeApplications { applicationList.update(updated.applications) }
                    snapshot = updated
                    try? await mixer.apply(mixTargets, outputUID: output?.uid)
                }
            }
            try? await mixer.finishOutputSwitch(guardTap)
            throw error
        }
    }

    private func perform(switching direction: AudioDirection? = nil, bluetoothID: String? = nil, _ operation: @escaping @MainActor () async throws -> Void) {
        guard enabled, !sleeping else { return }
        isWorking = true
        isAuthorizing = false
        switchingDevice = direction
        connectingBluetooth = bluetoothID
        operationError = nil
        let epoch = revision
        operationRevision &+= 1
        let command = operationRevision
        volumeWriter.cancelPending()
        mixTask?.cancel()
        mixTask = nil; mixRequests.reset()
        operationTask = Task { [weak self] in
            guard let self, operationRevision == command else { return }
            guard revision == epoch, enabled, !sleeping else {
                isWorking = false; isAuthorizing = false; switchingDevice = nil; connectingBluetooth = nil; operationTask = nil; return
            }
            do { try await operation() }
            catch is CancellationError { /* 关闭界面或休眠属于正常取消，不显示失败提示。 */ }
            catch { if operationRevision == command, revision == epoch { self.operationError = error as? AudioControlError ?? .unavailable } }
            guard operationRevision == command else { return }
            isWorking = false; isAuthorizing = false; switchingDevice = nil; connectingBluetooth = nil; operationTask = nil
            scheduleRefresh(immediate: true)
        }
    }

    private func installSleepObservers() {
        guard sleepObservers.isEmpty else { return }
        for (name, sleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sleeping = sleep
                    self.revision &+= 1
                    if sleep {
                        self.cancelPendingAudioOperation()
                        self.bluetoothRefreshTask?.cancel(); self.bluetoothDevices = []
                    } else if self.enabled, self.visible { self.refreshBluetoothDevices() }
                    self.updateWatchers()
                }
            }
            sleepObservers.append(observer)
        }
    }

    private func removeSleepObservers() {
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepObservers.removeAll()
    }

    func stop() {
        enabled = false
        applicationList.reset()
        cancelPendingAudioOperation()
        bluetoothRefreshTask?.cancel(); bluetoothRefreshTask = nil; bluetoothDevices = []
        pendingOutputApps.removeAll(); failedOutputApps.removeAll(); switchingDevice = nil; isAuthorizing = false
        revision &+= 1
        refreshTask?.cancel()
        mixTask?.cancel(); mixRequests.reset()
        playbackGraceTask?.cancel(); playbackGraceTask = nil; playbackGrace.reset()
        volumeWriter.cancelPending()
        removeSleepObservers()
        hardware.stopWatching()
        Task { await mixer.stop() }
    }
}
